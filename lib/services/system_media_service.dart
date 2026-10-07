import 'dart:async';
import 'dart:io' show Platform;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 系统媒体控件：把 media_kit 播放器的状态同步到 Android
/// MediaSession —— 视频加载/播放时，系统通知栏、锁屏、蓝牙耳机
/// 都能看到标题/封面/进度并控制播放暂停、拖动进度、下一集。
/// 系统侧的操作回调进当前绑定的播放器。仅 Android 生效。
class SystemMediaService {
  static SeleneMediaHandler? _handler;
  static Future<SeleneMediaHandler?>? _initializing;

  static Future<SeleneMediaHandler?> ensureInitialized() {
    if (!Platform.isAndroid) return Future.value(null);
    if (_handler != null) return Future.value(_handler);
    return _initializing ??= () async {
      try {
        _handler = await AudioService.init(
          builder: () => SeleneMediaHandler(),
          config: const AudioServiceConfig(
            androidNotificationChannelId:
                'top.dalongzhuazi.seleneall.channel.media',
            androidNotificationChannelName: '媒体播放',
            androidNotificationOngoing: false,
            androidStopForegroundOnPause: true,
          ),
        );
      } catch (e) {
        debugPrint('SystemMediaService init failed: $e');
      }
      return _handler;
    }();
  }

  static SeleneMediaHandler? get handler => _handler;
}

class SeleneMediaHandler extends BaseAudioHandler with SeekHandler {
  Player? _player;
  VoidCallback? onSkipToNext;
  final List<StreamSubscription<dynamic>> _subs = [];
  MediaItem? _currentItem;
  bool _completed = false;
  DateTime _lastPositionPublish = DateTime.fromMillisecondsSinceEpoch(0);

  void attachPlayer(Player player) {
    if (identical(_player, player)) return;
    _cancelSubs();
    _player = player;
    _subs.add(player.stream.playing.listen((_) => _publishState()));
    _subs.add(player.stream.buffering.listen((_) => _publishState()));
    _subs.add(player.stream.completed.listen((completed) {
      _completed = completed;
      _publishState();
    }));
    _subs.add(player.stream.position.listen((_) {
      // 系统侧会按 updatePosition + speed 自行外推进度，
      // 位置事件 1 秒发一次足够，避免通知频繁刷新。
      final now = DateTime.now();
      if (now.difference(_lastPositionPublish) <
          const Duration(seconds: 1)) {
        return;
      }
      _lastPositionPublish = now;
      _publishState();
    }));
    _subs.add(player.stream.duration.listen((duration) {
      final item = _currentItem;
      if (item != null &&
          duration > Duration.zero &&
          item.duration != duration) {
        _currentItem = item.copyWith(duration: duration);
        mediaItem.add(_currentItem);
      }
    }));
    _publishState();
  }

  void detachPlayer() {
    _cancelSubs();
    _player = null;
    _currentItem = null;
    mediaItem.add(null);
    playbackState.add(
      PlaybackState(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }

  void _cancelSubs() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
  }

  /// 播放新内容/切换集数时由播放器调用：更新标题/集数/封面，
  /// 并先进入 loading 态（加载阶段系统控件就已出现）。
  void notifyMediaChanged({
    required String id,
    required String title,
    String? sourceName,
    String? episodeLabel,
    Uri? artUri,
  }) {
    _completed = false;
    _currentItem = MediaItem(
      id: id,
      title: title,
      album: sourceName,
      displaySubtitle: episodeLabel,
      artUri: artUri,
    );
    mediaItem.add(_currentItem);
    _publishState(forceLoading: true);
  }

  void _publishState({bool forceLoading = false}) {
    final player = _player;
    if (player == null) return;
    final state = player.state;
    final processing = _completed
        ? AudioProcessingState.completed
        : forceLoading
            ? AudioProcessingState.loading
            : state.buffering
                ? AudioProcessingState.buffering
                : AudioProcessingState.ready;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          state.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processing,
        playing: state.playing,
        updatePosition: state.position,
        bufferedPosition: state.buffer,
        speed: state.rate,
        updateTime: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> play() async => _player?.play();

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> skipToNext() async => onSkipToNext?.call();

  @override
  Future<void> skipToPrevious() async {
    // 播放器本身没有「上一集」功能，系统上一曲键回到本集开头。
    await _player?.seek(Duration.zero);
  }

  @override
  Future<void> stop() async {
    _player?.pause();
    detachPlayer();
    await super.stop();
  }
}
