import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import '../services/danmaku_service.dart';
import '../services/super_res_service.dart';
import '../services/user_data_service.dart';
import 'danmaku_layer.dart';
import 'dlna_device_dialog.dart';

class MobilePlayerControls extends StatefulWidget {
  final Player player;
  final VideoState state;
  final Function(bool) onControlsVisibilityChanged;
  final VoidCallback? onBackPressed;
  final Function(bool) onFullscreenChange;
  final VoidCallback? onNextEpisode;
  final VoidCallback? onPause;
  final String videoUrl;
  final bool isLastEpisode;
  final bool isLoadingVideo;
  final Function(dynamic)? onCastStarted;
  final String? videoTitle;
  final int? currentEpisodeIndex;
  final int? totalEpisodes;
  final String? sourceName;
  final VoidCallback? onExitFullScreen;
  final bool live;
  final ValueNotifier<double> playbackSpeedListenable;
  final Future<void> Function(double speed) onSetSpeed;
  final Future<void> Function(SuperResMode mode) onSetSuperResMode;
  final Future<void> Function() onEnterPipMode;
  final bool isPipMode;

  const MobilePlayerControls({
    super.key,
    required this.player,
    required this.state,
    required this.onControlsVisibilityChanged,
    this.onBackPressed,
    required this.onFullscreenChange,
    this.onNextEpisode,
    this.onPause,
    required this.videoUrl,
    this.isLastEpisode = false,
    this.isLoadingVideo = false,
    this.onCastStarted,
    this.videoTitle,
    this.currentEpisodeIndex,
    this.totalEpisodes,
    this.sourceName,
    this.onExitFullScreen,
    this.live = false,
    required this.playbackSpeedListenable,
    required this.onSetSpeed,
    required this.onSetSuperResMode,
    required this.onEnterPipMode,
    required this.isPipMode,
  });

  @override
  State<MobilePlayerControls> createState() => _MobilePlayerControlsState();
}

class _MobilePlayerControlsState extends State<MobilePlayerControls> {
  final List<StreamSubscription> _subscriptions = [];
  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool _isLongPressing = false;
  double _originalPlaybackSpeed = 1.0;
  Duration? _dragPosition;
  bool _isSeekingViaSwipe = false;
  double _swipeStartX = 0;
  Duration _swipeStartPosition = Duration.zero;
  Size? _screenSize;
  bool _isLocked = false;
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  double _currentVolume = 0.5;
  double _currentBrightness = 0.5;
  Timer? _volumeHideTimer;
  Timer? _brightnessHideTimer;
  Timer? _timeUpdateTimer;
  String _currentTime = '';
  SuperResMode _superResMode = SuperResMode.off;
  // 两侧点按快退/快进的反馈
  String? _seekFeedbackText;
  bool _seekFeedbackIsLeft = true;
  Timer? _seekFeedbackTimer;
  // 长按左侧 2 倍快退
  bool _isRewinding = false;
  bool _wasPlayingBeforeRewind = false;
  Timer? _rewindTimer;
  // 缓冲状态与缓存信息（从 mpv 属性轮询：缓冲进度/已缓存时长/网速）
  bool _isBuffering = false;
  int? _cacheBufferingPct;
  double? _cacheDurationSecs;
  int? _cacheSpeedBps;
  Timer? _speedPollTimer;
  // 超分开启提示（短暂徽标）
  String? _superResBadgeText;
  Timer? _superResBadgeTimer;
  // 弹幕
  bool _danmakuEnabled = true;
  double _danmakuOpacity = 0.85;
  double _danmakuFontScale = 1.0;
  double _danmakuArea = 0.6;
  List<DanmakuItem> _danmakuItems = const [];
  String? _danmakuMatchLabel;
  bool _danmakuLoading = false;
  int _danmakuGeneration = 0;
  String? _danmakuToastText;
  Timer? _danmakuToastTimer;

  @override
  void initState() {
    super.initState();
    _initSystemControls();
    _listenPlayerStreams();
    _updateCurrentTime();
    _startTimeUpdateTimer();
    UserDataService.getSuperResMode().then((mode) {
      if (mounted) {
        setState(() => _superResMode = mode);
        // 已开着超分进入播放：短暂显示徽标，让用户确认确实生效中
        if (mode != SuperResMode.off) {
          Future.delayed(const Duration(milliseconds: 900), () {
            if (mounted) _showSuperResBadge();
          });
        }
      }
    }).catchError((_) {});
    _initDanmaku();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _forceStartHideTimer();
      widget.onControlsVisibilityChanged(true);
      _updateBufferPolling();
    });
  }

  @override
  void didUpdateWidget(covariant MobilePlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当 PIP 模式停止时，显示控制栏
    if (oldWidget.isPipMode && !widget.isPipMode) {
      setState(() => _controlsVisible = true);
      widget.onControlsVisibilityChanged(true);
      _startHideTimer();
    }
    if (oldWidget.isLoadingVideo != widget.isLoadingVideo) {
      _updateBufferPolling();
    }
    // 换集/换源（videoUrl 变化）后重新匹配弹幕
    if (oldWidget.videoUrl != widget.videoUrl && _danmakuEnabled) {
      _danmakuItems = const [];
      _danmakuMatchLabel = null;
      _loadDanmakuAuto();
    }
  }

  void _initSystemControls() {
    VolumeController.instance.showSystemUI = false;
    VolumeController.instance.getVolume().then((value) {
      if (mounted) {
        setState(() => _currentVolume = value);
      }
    }).catchError((_) {});
    ScreenBrightness().application.then((value) {
      if (mounted) {
        setState(() => _currentBrightness = value);
      }
    }).catchError((_) {});
  }

  void _listenPlayerStreams() {
    _subscriptions.add(widget.player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing && _controlsVisible) {
        _startHideTimer();
      }
      if (!playing) {
        _hideTimer?.cancel();
        if (!_controlsVisible) {
          setState(() => _controlsVisible = true);
          widget.onControlsVisibilityChanged(true);
        }
      }
    }));

    _subscriptions.add(widget.player.stream.position.listen((_) {
      if (!mounted) return;
      if (_controlsVisible && !_isSeekingViaSwipe) {
        setState(() {});
      }
    }));

    _subscriptions.add(widget.player.stream.completed.listen((_) {
      if (!mounted) return;
      setState(() {});
    }));

    _subscriptions.add(widget.player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      setState(() => _isBuffering = buffering);
      _updateBufferPolling();
    }));
  }

  /// 缓冲/初始加载期间轮询 mpv 缓存属性：cache-buffering-state（缓冲
  /// 进度 %）、demuxer-cache-duration（已缓存秒数）、cache-speed（网速）。
  /// 数据存字段驱动 UI 刷新——上一版只在网速变化时刷新且百分比取自
  /// player.state.buffer，网速恒定时界面就冻住了（用户实测卡 0%）。
  void _updateBufferPolling() {
    if (_isBuffering || widget.isLoadingVideo) {
      if (_speedPollTimer == null) {
        _pollBufferStats();
        _speedPollTimer = Timer.periodic(
          const Duration(milliseconds: 400),
          (_) => _pollBufferStats(),
        );
      }
    } else {
      _speedPollTimer?.cancel();
      _speedPollTimer = null;
      _cacheBufferingPct = null;
      _cacheDurationSecs = null;
      _cacheSpeedBps = null;
    }
  }

  Future<void> _pollBufferStats() async {
    final platform = widget.player.platform;
    if (platform is! NativePlayer) return;
    try {
      final results = await Future.wait([
        platform.getProperty('cache-buffering-state'),
        platform.getProperty('demuxer-cache-duration'),
        platform.getProperty('cache-speed'),
      ]);
      if (!mounted) return;
      final pct = int.tryParse(results[0].trim());
      final dur = double.tryParse(results[1].trim());
      final spd = int.tryParse(results[2].trim());
      if (pct != _cacheBufferingPct ||
          dur != _cacheDurationSecs ||
          spd != _cacheSpeedBps) {
        setState(() {
          _cacheBufferingPct = pct;
          _cacheDurationSecs = dur;
          _cacheSpeedBps = spd;
        });
      }
    } catch (_) {}
  }

  /// 缓冲信息文案（百分比/已缓存秒数/网速），加载层与缓冲浮层共用。
  String _bufferingInfoText() {
    final parts = <String>[];
    if (_cacheBufferingPct != null) {
      parts.add('缓冲 $_cacheBufferingPct%');
    }
    if (_cacheDurationSecs != null && _cacheDurationSecs! >= 1) {
      parts.add('已缓存 ${_cacheDurationSecs!.toStringAsFixed(0)} 秒');
    }
    if (_cacheSpeedBps != null && _cacheSpeedBps! > 0) {
      parts.add(_formatSpeed(_cacheSpeedBps!));
    }
    return parts.join(' · ');
  }

  String _formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    }
    return '$bytesPerSecond B/s';
  }

  /// 显示超分状态徽标（开启确认/失败提示），约 1.8 秒后自动消失。
  void _showSuperResBadge() {
    final status = SuperResService.lastStatus;
    String text;
    if (status != null && status.mode == _superResMode && status.error != null) {
      text = '超分开启失败：着色器加载异常';
    } else if (status != null &&
        status.mode == _superResMode &&
        status.shaderCount > 0) {
      text = '超分已开启 · ${_superResMode.label}（${status.shaderCount} 个着色器）';
    } else {
      text = '超分已开启 · ${_superResMode.label}';
    }
    setState(() => _superResBadgeText = text);
    _superResBadgeTimer?.cancel();
    _superResBadgeTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _superResBadgeText = null);
    });
  }

  // ---------------- 弹幕 ----------------

  Future<void> _initDanmaku() async {
    if (widget.live) return;
    final results = await Future.wait([
      UserDataService.getDanmakuEnabled(),
      UserDataService.getDanmakuOpacity(),
      UserDataService.getDanmakuFontScale(),
      UserDataService.getDanmakuArea(),
    ]);
    if (!mounted) return;
    setState(() {
      _danmakuEnabled = results[0] as bool;
      _danmakuOpacity = results[1] as double;
      _danmakuFontScale = results[2] as double;
      _danmakuArea = results[3] as double;
    });
    if (_danmakuEnabled) {
      _loadDanmakuAuto();
    }
  }

  String _danmakuFileName() {
    final title = widget.videoTitle ?? '';
    final index = widget.currentEpisodeIndex;
    if (index != null && (widget.totalEpisodes ?? 0) > 1) {
      return '$title 第${index + 1}集';
    }
    return title;
  }

  Future<void> _loadDanmakuAuto() async {
    if (widget.live || (widget.videoTitle ?? '').isEmpty) return;
    final gen = ++_danmakuGeneration;
    setState(() => _danmakuLoading = true);
    final match = await DanmakuService.autoMatch(_danmakuFileName());
    if (!mounted || gen != _danmakuGeneration) return;
    if (match == null) {
      setState(() {
        _danmakuLoading = false;
        _danmakuMatchLabel = null;
      });
      return;
    }
    await _loadDanmakuForEpisode(
      gen,
      match.episodeId,
      '${match.animeTitle} · ${match.episodeTitle}',
    );
  }

  Future<void> _loadDanmakuForEpisode(
    int gen,
    int episodeId,
    String label,
  ) async {
    final items = await DanmakuService.fetchComments(episodeId);
    if (!mounted || gen != _danmakuGeneration) return;
    setState(() {
      _danmakuItems = items;
      _danmakuLoading = false;
      _danmakuMatchLabel = label;
    });
    if (items.isNotEmpty) {
      _showDanmakuToast('弹幕已加载 ${items.length} 条 · $label');
    } else {
      _showDanmakuToast('该集暂无弹幕 · $label');
    }
  }

  void _showDanmakuToast(String text) {
    setState(() => _danmakuToastText = text);
    _danmakuToastTimer?.cancel();
    _danmakuToastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _danmakuToastText = null);
    });
  }

  Future<void> _toggleDanmaku() async {
    final next = !_danmakuEnabled;
    setState(() => _danmakuEnabled = next);
    await UserDataService.setDanmakuEnabled(next);
    if (next && _danmakuItems.isEmpty && !_danmakuLoading) {
      _loadDanmakuAuto();
    }
  }

  Future<void> _showDanmakuSettings() async {
    _onUserInteraction();
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        final fg = isDark ? Colors.white : Colors.black87;
        final sub = isDark ? Colors.white60 : Colors.black54;
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              Widget sliderRow(
                String label,
                double value,
                double min,
                double max,
                String display,
                ValueChanged<double> onChanged,
              ) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        child: Text(label,
                            style: TextStyle(color: fg, fontSize: 13.5)),
                      ),
                      Expanded(
                        child: Slider(
                          value: value.clamp(min, max),
                          min: min,
                          max: max,
                          onChanged: (v) {
                            setSheetState(() {});
                            onChanged(v);
                          },
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(display,
                            style: TextStyle(color: sub, fontSize: 12)),
                      ),
                    ],
                  ),
                );
              }

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      '弹幕设置',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold, color: fg),
                    ),
                  ),
                  if (_danmakuMatchLabel != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        '当前：$_danmakuMatchLabel（${_danmakuItems.length} 条）',
                        style: TextStyle(fontSize: 12, color: sub),
                      ),
                    ),
                  sliderRow(
                      '不透明度', _danmakuOpacity, 0.3, 1.0,
                      '${(_danmakuOpacity * 100).round()}%', (v) {
                    setState(() => _danmakuOpacity = v);
                    UserDataService.setDanmakuOpacity(v);
                  }),
                  sliderRow('字号', _danmakuFontScale, 0.7, 1.4,
                      '${(_danmakuFontScale * 100).round()}%', (v) {
                    setState(() => _danmakuFontScale = v);
                    UserDataService.setDanmakuFontScale(v);
                  }),
                  sliderRow('显示区域', _danmakuArea, 0.25, 1.0,
                      '${(_danmakuArea * 100).round()}%', (v) {
                    setState(() => _danmakuArea = v);
                    UserDataService.setDanmakuArea(v);
                  }),
                  ListTile(
                    leading: Icon(Icons.search, color: fg),
                    title: Text('手动选择弹幕（匹配不对时用）',
                        style: TextStyle(color: fg, fontSize: 14)),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _showDanmakuSearch();
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showDanmakuSearch() async {
    final picked = await showModalBottomSheet<DanmakuEpisode>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _DanmakuPickerSheet(
        initialKeyword: widget.videoTitle ?? '',
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _danmakuEnabled = true;
      _danmakuLoading = true;
    });
    await UserDataService.setDanmakuEnabled(true);
    final gen = ++_danmakuGeneration;
    await _loadDanmakuForEpisode(gen, picked.episodeId, picked.episodeTitle);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _hideTimer?.cancel();
    _volumeHideTimer?.cancel();
    _brightnessHideTimer?.cancel();
    _timeUpdateTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _rewindTimer?.cancel();
    _speedPollTimer?.cancel();
    _superResBadgeTimer?.cancel();
    _danmakuToastTimer?.cancel();
    VolumeController.instance.showSystemUI = true;
    super.dispose();
  }

  bool get _isFullscreen => widget.state.isFullscreen();
  bool get _isPlaying => widget.player.state.playing;
  Duration get _position => widget.player.state.position;
  Duration get _duration => widget.player.state.duration;

  void _startHideTimer() {
    _hideTimer?.cancel();
    if (_isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() => _controlsVisible = false);
          widget.onControlsVisibilityChanged(false);
        }
      });
    }
  }

  void _forceStartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _controlsVisible = false);
        widget.onControlsVisibilityChanged(false);
      }
    });
  }

  void _onUserInteraction() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
      widget.onControlsVisibilityChanged(true);
    }
    _startHideTimer();
  }

  void _toggleControlsVisibility() {
    if (_isLocked) {
      setState(() => _controlsVisible = !_controlsVisible);
      if (_controlsVisible) {
        _startHideTimer();
      } else {
        _hideTimer?.cancel();
      }
      return;
    }
    setState(() => _controlsVisible = !_controlsVisible);
    widget.onControlsVisibilityChanged(_controlsVisible);
    if (_controlsVisible) {
      _startHideTimer();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _onLongPressStart(LongPressStartDetails details) {
    if (_isLocked || widget.live || !_isPlaying) return;
    setState(() {
      _isLongPressing = true;
      _originalPlaybackSpeed = widget.playbackSpeedListenable.value;
    });
    widget.onSetSpeed(2.0);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (_isLocked || !_isLongPressing || widget.live) return;
    widget.onSetSpeed(_originalPlaybackSpeed);
    setState(() => _isLongPressing = false);
  }

  /// 点按屏幕左/右侧：按视频总长 1% 快退/快进（长视频步长大、短视频步长小）。
  void _onSideTapSeek(bool isLeft) {
    if (_isLocked || widget.live) {
      _toggleControlsVisibility();
      return;
    }
    final duration = _duration;
    if (duration == Duration.zero) {
      _toggleControlsVisibility();
      return;
    }
    var step = Duration(milliseconds: duration.inMilliseconds ~/ 100);
    if (step < const Duration(seconds: 1)) {
      step = const Duration(seconds: 1);
    }
    final targetMs = isLeft
        ? _position.inMilliseconds - step.inMilliseconds
        : _position.inMilliseconds + step.inMilliseconds;
    final clamped = targetMs.clamp(0, duration.inMilliseconds);
    widget.player.seek(Duration(milliseconds: clamped));
    setState(() {
      _seekFeedbackIsLeft = isLeft;
      _seekFeedbackText = '${isLeft ? '-' : '+'}${_formatDuration(step)}';
    });
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFeedbackText = null);
    });
    _onUserInteraction();
  }

  /// 长按左侧：2 倍速快退（暂停并以 2 倍墙钟速度回退进度），松手恢复。
  void _onRewindStart(LongPressStartDetails details) {
    if (_isLocked || widget.live || _duration == Duration.zero) return;
    _wasPlayingBeforeRewind = _isPlaying;
    if (_isPlaying) {
      widget.player.pause();
    }
    setState(() => _isRewinding = true);
    _hideTimer?.cancel();
    _rewindTimer?.cancel();
    _rewindTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) {
      final pos = widget.player.state.position;
      final back = pos - const Duration(milliseconds: 500);
      widget.player
          .seek(back < Duration.zero ? Duration.zero : back);
    });
  }

  void _onRewindEnd() {
    if (!_isRewinding) return;
    _rewindTimer?.cancel();
    _rewindTimer = null;
    setState(() => _isRewinding = false);
    if (_wasPlayingBeforeRewind) {
      widget.player.play();
    }
    _onUserInteraction();
  }

  void _onSwipeStart(DragStartDetails details) {
    if (_isLocked || widget.live) return;
    _screenSize ??= MediaQuery.of(context).size;
    setState(() {
      _isSeekingViaSwipe = true;
      _swipeStartX = details.globalPosition.dx;
      _swipeStartPosition = _position;
      _dragPosition = null;
      _controlsVisible = true;
    });
    _hideTimer?.cancel();
  }

  void _onSwipeUpdate(DragUpdateDetails details) {
    if (_isLocked || !_isSeekingViaSwipe || widget.live || _screenSize == null)
      return;
    final screenWidth = _screenSize!.width;
    final swipeDistance = details.globalPosition.dx - _swipeStartX;
    final swipeRatio = swipeDistance / (screenWidth * 0.5);
    final duration = _duration;
    if (duration == Duration.zero) return;
    final targetPosition = _swipeStartPosition +
        Duration(
          milliseconds: (duration.inMilliseconds * swipeRatio * 0.1).round(),
        );
    final clamped = Duration(
      milliseconds:
          targetPosition.inMilliseconds.clamp(0, duration.inMilliseconds),
    );
    setState(() => _dragPosition = clamped);
  }

  void _onSwipeEnd(DragEndDetails details) {
    if (_isLocked || !_isSeekingViaSwipe || widget.live) return;
    if (_dragPosition != null) {
      widget.player.seek(_dragPosition!);
    }
    setState(() {
      _isSeekingViaSwipe = false;
      _dragPosition = null;
    });
    _startHideTimer();
  }

  void _onVolumeSwipeStart(DragStartDetails details) {
    if (!_isFullscreen || _isLocked) return;
    _volumeHideTimer?.cancel();
    _hideTimer?.cancel();
    setState(() => _controlsVisible = true);
  }

  void _onVolumeSwipeUpdate(DragUpdateDetails details) {
    if (!_isFullscreen || _isLocked) return;
    final screenHeight = MediaQuery.of(context).size.height;
    final volumeChange = -(details.delta.dy / screenHeight) * 2;
    setState(() {
      _currentVolume = (_currentVolume + volumeChange).clamp(0.0, 1.0);
      _showVolumeIndicator = true;
    });
    VolumeController.instance.setVolume(_currentVolume);
    _startVolumeHideTimer();
  }

  void _onVolumeSwipeEnd(DragEndDetails details) {
    if (!_isFullscreen || _isLocked) return;
    _startVolumeHideTimer();
    _startHideTimer();
  }

  void _startVolumeHideTimer() {
    _volumeHideTimer?.cancel();
    _volumeHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _showVolumeIndicator = false);
      }
    });
  }

  void _onBrightnessSwipeStart(DragStartDetails details) {
    if (!_isFullscreen || _isLocked) return;
    _brightnessHideTimer?.cancel();
    _hideTimer?.cancel();
    setState(() => _controlsVisible = true);
  }

  void _onBrightnessSwipeUpdate(DragUpdateDetails details) {
    if (!_isFullscreen || _isLocked) return;
    final screenHeight = MediaQuery.of(context).size.height;
    final brightnessChange = -(details.delta.dy / screenHeight) * 2;
    setState(() {
      _currentBrightness =
          (_currentBrightness + brightnessChange).clamp(0.0, 1.0);
      _showBrightnessIndicator = true;
    });
    ScreenBrightness().setApplicationScreenBrightness(_currentBrightness);
    _startBrightnessHideTimer();
  }

  void _onBrightnessSwipeEnd(DragEndDetails details) {
    if (!_isFullscreen || _isLocked) return;
    _startBrightnessHideTimer();
    _startHideTimer();
  }

  void _startBrightnessHideTimer() {
    _brightnessHideTimer?.cancel();
    _brightnessHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _showBrightnessIndicator = false);
      }
    });
  }

  void _updateCurrentTime() {
    final now = DateTime.now();
    setState(() {
      _currentTime = DateFormat('HH:mm').format(now);
    });
  }

  void _startTimeUpdateTimer() {
    _timeUpdateTimer?.cancel();
    _timeUpdateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        _updateCurrentTime();
      }
    });
  }

  Future<void> _togglePlayPause() async {
    _onUserInteraction();
    if (_isPlaying) {
      await widget.player.pause();
      if (!mounted) return;
      widget.onPause?.call();
    } else {
      await widget.player.play();
    }
  }

  void _enterFullscreen() {
    widget.state.enterFullscreen();
    widget.onFullscreenChange(true);
    _onUserInteraction();
  }

  void _exitFullscreen() {
    widget.state.exitFullscreen();
    widget.onFullscreenChange(false);
    // 触发退出全屏回调
    widget.onExitFullScreen?.call();
    // 确保控制栏可见并重新启动隐藏计时器
    setState(() {
      _controlsVisible = true;
      _isLocked = false;
    });
    widget.onControlsVisibilityChanged(true);
    _startHideTimer();
  }

  Future<void> _showDLNADialog() async {
    if (_isPlaying) {
      await widget.player.pause();
      if (!mounted) return;
      widget.onPause?.call();
    }
    if (_isFullscreen) {
      _exitFullscreen();
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted) return;
    }
    if (!mounted) return;
    final resumePos = widget.player.state.position;
    await showDialog(
      context: context,
      builder: (context) => DLNADeviceDialog(
        currentUrl: widget.videoUrl,
        resumePosition: resumePos,
        videoTitle: widget.videoTitle,
        currentEpisodeIndex: widget.currentEpisodeIndex,
        totalEpisodes: widget.totalEpisodes,
        sourceName: widget.sourceName,
        onCastStarted: widget.onCastStarted,
      ),
    );
  }

  Future<void> _showSpeedDialog() async {
    final speeds = [0.5, 0.75, 1.0, 1.5, 2.0];
    final currentSpeed = widget.playbackSpeedListenable.value;
    final screenHeight = MediaQuery.of(context).size.height;
    final result = await showModalBottomSheet<double>(
      context: context,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: screenHeight * 0.75,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: speeds.map((speed) {
                  final selected = (speed - currentSpeed).abs() < 0.01;
                  return ListTile(
                    title: Text(
                      '${speed}x',
                      style: TextStyle(
                        color: selected
                            ? Colors.red
                            : (isDark ? Colors.white : Colors.black87),
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop(speed),
                  );
                }).toList(),
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (result != null) {
      await widget.onSetSpeed(result);
    }
  }

  Future<void> _showSuperResDialog() async {
    final screenHeight = MediaQuery.of(context).size.height;
    final result = await showModalBottomSheet<SuperResMode>(
      context: context,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: screenHeight * 0.75,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '超分（Anime4K）',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  ...SuperResMode.values.map((mode) {
                    final selected = mode == _superResMode;
                    return ListTile(
                      title: Text(
                        mode.label,
                        style: TextStyle(
                          color: selected
                              ? Colors.red
                              : (isDark ? Colors.white : Colors.black87),
                          fontWeight:
                              selected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      subtitle: Text(
                        mode.description,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white60 : Colors.black54,
                        ),
                      ),
                      onTap: () => Navigator.of(context).pop(mode),
                    );
                  }),
                  Builder(builder: (context) {
                    final status = SuperResService.lastStatus;
                    final vw = widget.player.state.width;
                    final vh = widget.player.state.height;
                    final String statusText;
                    final Color statusColor;
                    if (status == null || status.mode == SuperResMode.off) {
                      statusText = '当前状态：未开启';
                      statusColor =
                          isDark ? Colors.white54 : Colors.black54;
                    } else if (status.error != null) {
                      statusText =
                          '当前状态：着色器加载异常（${status.error}）';
                      statusColor = Colors.redAccent;
                    } else if (status.shaderCount > 0) {
                      statusText =
                          '当前状态：已生效 · ${status.shaderCount} 个着色器在链';
                      statusColor = Colors.green;
                    } else {
                      statusText = '当前状态：未读回着色器，可能未生效';
                      statusColor = Colors.orange;
                    }
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                      child: Text(
                        vw != null && vh != null && vw > 0
                            ? '$statusText · 视频 ${vw}×$vh'
                            : statusText,
                        style: TextStyle(fontSize: 12, color: statusColor),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) return;
    if (result != null) {
      setState(() => _superResMode = result);
      await widget.onSetSuperResMode(result);
      if (!mounted) return;
      if (result != SuperResMode.off) {
        // 等父层把着色器应用完（回读在 SuperResService.lastStatus 里），
        // 再显示带验证信息的徽标
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted && _superResMode != SuperResMode.off) {
            _showSuperResBadge();
          }
        });
      }
    }
  }

  Future<void> _enterPipMode() async {
    debugPrint('_enterPipMode');
    // 隐藏控制栏
    setState(() => _controlsVisible = false);
    widget.onControlsVisibilityChanged(false);
    _hideTimer?.cancel();
    // 调用父层的 PIP 逻辑
    await widget.onEnterPipMode();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoadingVideo) {
      final info = _bufferingInfoText();
      return Container(
        color: Colors.black.withValues(alpha: 0.7),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 3),
              const SizedBox(height: 16),
              const Text('加载中...',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              if (info.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(info,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12.5)),
              ],
            ],
          ),
        ),
      );
    }

    Widget content = Stack(
      children: [
        if (_danmakuEnabled && _danmakuItems.isNotEmpty)
          Positioned.fill(
            child: DanmakuLayer(
              player: widget.player,
              items: _danmakuItems,
              opacity: _danmakuOpacity,
              fontScale: _danmakuFontScale,
              areaRatio: _danmakuArea,
            ),
          ),
        Positioned.fill(child: _buildGestureLayer()),
        _buildTopGradient(),
        _buildBottomGradient(),
        if (_isFullscreen) _buildCurrentTime(),
        _buildBackButton(),
        _buildCastButton(),
        _buildCenterPlayPause(),
        _buildProgressBar(),
        _buildBottomControls(),
        if ((_isLongPressing || _isRewinding) && !_isLocked)
          _buildLongPressIndicator(),
        if (_seekFeedbackText != null) _buildSeekFeedback(),
        if (_isBuffering && !widget.isLoadingVideo) _buildBufferingOverlay(),
        if (_isFullscreen) _buildSideSeekButtons(),
        if (_superResMode != SuperResMode.off) _buildSuperResPill(),
        if (_superResBadgeText != null) _buildSuperResBadge(),
        if (_danmakuToastText != null) _buildDanmakuToast(),
        if (_isFullscreen && _showBrightnessIndicator && !_isLocked)
          _buildBrightnessIndicator(),
        if (_isFullscreen) _buildRightOverlay(),
      ],
    );

    if (_isFullscreen) {
      content = PopScope(
        canPop: !_isLocked,
        onPopInvokedWithResult: (didPop, result) async {
          if (!didPop && _isLocked) {
            setState(() {
              _isLocked = false;
              _controlsVisible = true;
            });
            _startHideTimer();
          }
        },
        child: content,
      );
    }

    return content;
  }

  Widget _buildGestureLayer() {
    return Positioned.fill(
      child: Row(
        children: [
          if (_isFullscreen)
            Expanded(
              flex: 1,
              child: GestureDetector(
                onTap: _toggleControlsVisibility,
                onLongPressStart: _onRewindStart,
                onLongPressEnd: (_) => _onRewindEnd(),
                onLongPressCancel: _onRewindEnd,
                onHorizontalDragStart: _onSwipeStart,
                onHorizontalDragUpdate: _onSwipeUpdate,
                onHorizontalDragEnd: _onSwipeEnd,
                onVerticalDragStart: _onBrightnessSwipeStart,
                onVerticalDragUpdate: _onBrightnessSwipeUpdate,
                onVerticalDragEnd: _onBrightnessSwipeEnd,
                behavior: HitTestBehavior.opaque,
              ),
            ),
          Expanded(
            flex: _isFullscreen ? 2 : 1,
            child: GestureDetector(
              onTap: _toggleControlsVisibility,
              onLongPressStart: _onLongPressStart,
              onLongPressEnd: _onLongPressEnd,
              onLongPressCancel: () {
                if (_isLongPressing) {
                  _onLongPressEnd(const LongPressEndDetails());
                }
              },
              onHorizontalDragStart: _onSwipeStart,
              onHorizontalDragUpdate: _onSwipeUpdate,
              onHorizontalDragEnd: _onSwipeEnd,
              behavior: HitTestBehavior.opaque,
            ),
          ),
          if (_isFullscreen)
            Expanded(
              flex: 1,
              child: GestureDetector(
                onTap: _toggleControlsVisibility,
                onLongPressStart: _onLongPressStart,
                onLongPressEnd: _onLongPressEnd,
                onLongPressCancel: () {
                  if (_isLongPressing) {
                    _onLongPressEnd(const LongPressEndDetails());
                  }
                },
                onHorizontalDragStart: _onSwipeStart,
                onHorizontalDragUpdate: _onSwipeUpdate,
                onHorizontalDragEnd: _onSwipeEnd,
                onVerticalDragStart: _onVolumeSwipeStart,
                onVerticalDragUpdate: _onVolumeSwipeUpdate,
                onVerticalDragEnd: _onVolumeSwipeEnd,
                behavior: HitTestBehavior.opaque,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTopGradient() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          child: Container(
            height: _isFullscreen ? 120 : 80,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.6),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentTime() {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          child: Center(
            child: Text(
              _currentTime,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomGradient() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          child: Container(
            height: _isFullscreen ? 140 : 100,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.6),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackButton() {
    return Positioned(
      top: _isFullscreen ? 8 : 4,
      left: _isFullscreen ? 16.0 : 8.0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controlsVisible || _isLocked,
          child: GestureDetector(
            onTap: () {
              _onUserInteraction();
              if (_isFullscreen) {
                _exitFullscreen();
              } else {
                widget.onBackPressed?.call();
              }
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.arrow_back,
                color: Colors.white,
                size: _isFullscreen ? 24 : 20,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCastButton() {
    return Positioned(
      top: _isFullscreen ? 8 : 4,
      right: _isFullscreen ? 16.0 : 8.0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controlsVisible || _isLocked,
          child: GestureDetector(
            onTap: () async {
              _onUserInteraction();
              if (!widget.live) {
                widget.player.pause();
              }
              await _showDLNADialog();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.cast,
                color: Colors.white,
                size: _isFullscreen ? 24 : 20,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterPlayPause() {
    return Positioned.fill(
      child: Center(
        child: AnimatedOpacity(
          opacity:
              (!_isLocked && (!_isPlaying || _controlsVisible)) ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: _isLocked || (_isPlaying && !_controlsVisible),
            child: GestureDetector(
              onTap: _togglePlayPause,
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: _isFullscreen ? 64 : 48,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    return Positioned(
      bottom: _isFullscreen ? 58.0 : 42.0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controlsVisible || _isLocked,
          child: Container(
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: _MobileVideoProgressBar(
              player: widget.player,
              live: widget.live,
              onDragStart: () {
                setState(() => _controlsVisible = true);
                _hideTimer?.cancel();
              },
              onDragEnd: () {
                setState(() => _dragPosition = null);
                _startHideTimer();
              },
              onDragUpdate: () {
                if (!_controlsVisible) {
                  setState(() => _controlsVisible = true);
                }
                _hideTimer?.cancel();
              },
              onPositionUpdate: (duration) {
                setState(() => _dragPosition = duration);
              },
              dragPosition: _dragPosition,
              isSeekingViaSwipe: _isSeekingViaSwipe,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final position = _dragPosition ?? _position;
    final duration = _duration;
    return Positioned(
      bottom: _isFullscreen ? 4.0 : -6.0,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controlsVisible || _isLocked,
          child: Padding(
            padding: EdgeInsets.only(
              left: _isFullscreen ? 16.0 : 8.0,
              right: _isFullscreen ? 16.0 : 8.0,
              bottom: _isFullscreen ? 8.0 : 8.0,
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _togglePlayPause,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
                    child: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: _isFullscreen ? 28 : 24,
                    ),
                  ),
                ),
                if (!widget.isLastEpisode && !widget.live)
                  GestureDetector(
                    onTap: () {
                      _onUserInteraction();
                      widget.onNextEpisode?.call();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.skip_next,
                        color: Colors.white,
                        size: _isFullscreen ? 28 : 24,
                      ),
                    ),
                  ),
                if (!widget.live)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8.0, right: 8.0),
                      child: Text(
                        '${_formatDuration(position)} / ${_formatDuration(duration)}',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                if (widget.live) const Spacer(),
                if (!widget.live)
                  GestureDetector(
                    onTap: () async {
                      _onUserInteraction();
                      await _toggleDanmaku();
                    },
                    onLongPress: () async {
                      await _showDanmakuSettings();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: EdgeInsets.only(right: _isFullscreen ? 22 : 10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _danmakuEnabled
                                ? Colors.red
                                : Colors.white54,
                            width: 1.2,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          '弹',
                          style: TextStyle(
                            color: _danmakuEnabled
                                ? Colors.red
                                : Colors.white54,
                            fontSize: _isFullscreen ? 12.5 : 11.5,
                            fontWeight: FontWeight.bold,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (!widget.live)
                  GestureDetector(
                    onTap: () async {
                      _onUserInteraction();
                      await _showSpeedDialog();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: EdgeInsets.only(right: _isFullscreen ? 22 : 10),
                      child: Icon(
                        Icons.speed,
                        color: Colors.white,
                        size: _isFullscreen ? 22 : 20,
                      ),
                    ),
                  ),
                if (!widget.live)
                  GestureDetector(
                    onTap: () async {
                      _onUserInteraction();
                      await _showSuperResDialog();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: EdgeInsets.only(right: _isFullscreen ? 22 : 10),
                      child: Text(
                        '超分',
                        style: TextStyle(
                          color: _superResMode != SuperResMode.off
                              ? Colors.red
                              : Colors.white,
                          fontSize: _isFullscreen ? 14 : 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                if (Platform.isAndroid)
                  GestureDetector(
                    onTap: () async {
                      print('PIP button clicked!');
                      _onUserInteraction();
                      await _enterPipMode();
                    },
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.picture_in_picture_alt,
                        color: Colors.white,
                        size: _isFullscreen ? 22 : 20,
                      ),
                    ),
                  ),
                GestureDetector(
                  onTap: () {
                    _onUserInteraction();
                    if (_isFullscreen) {
                      _exitFullscreen();
                    } else {
                      _enterFullscreen();
                    }
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: EdgeInsets.only(left: _isFullscreen ? 12 : 5, right: _isFullscreen ? 12 : 8),
                    child: Icon(
                      _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: Colors.white,
                      size: _isFullscreen ? 28 : 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLongPressIndicator() {
    final rewinding = _isRewinding;
    return Positioned(
      top: 12,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(rewinding ? Icons.fast_rewind : Icons.fast_forward,
                  color: Colors.white, size: 26),
              const SizedBox(width: 7),
              Text(rewinding ? '2x 快退中' : '2x 快进中',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }

  /// 两侧点按快退/快进的反馈（对应一侧的圆形图标 + 步长）。
  Widget _buildSeekFeedback() {
    final isLeft = _seekFeedbackIsLeft;
    return Positioned(
      left: isLeft ? 40 : null,
      right: isLeft ? null : 40,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isLeft ? Icons.fast_rewind : Icons.fast_forward,
                  color: Colors.white, size: 20),
              const SizedBox(width: 6),
              Text(
                _seekFeedbackText!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 缓冲浮层：屏幕中下部居中（不依赖底部布局，全屏/窗口一致显示），
  /// 展示缓冲进度、已缓存时长与实时网速。
  Widget _buildBufferingOverlay() {
    final info = _bufferingInfoText();
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: const Alignment(0, 0.45),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                ),
                const SizedBox(width: 9),
                Text(
                  info.isEmpty ? '缓冲中…' : info,
                  style:
                      const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 两侧可见的快退/快进按钮（随控制栏显隐）：点按按总长 1% 跳进，
  /// 明确按钮避免整侧点按误触；长按快退/快进仍走整屏手势、无按钮。
  Widget _buildSideSeekButtons() {
    if (widget.live || _isLocked || _duration == Duration.zero) {
      return const SizedBox.shrink();
    }
    var step = Duration(milliseconds: _duration.inMilliseconds ~/ 100);
    if (step < const Duration(seconds: 1)) {
      step = const Duration(seconds: 1);
    }
    Widget button(bool isLeft) {
      return GestureDetector(
        onTap: () => _onSideTapSeek(isLeft),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withValues(alpha: 0.35),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(isLeft ? Icons.fast_rewind : Icons.fast_forward,
                  color: Colors.white, size: 24),
              Text(
                '${isLeft ? '-' : '+'}${_formatDuration(step)}',
                style: const TextStyle(color: Colors.white, fontSize: 9),
              ),
            ],
          ),
        ),
      );
    }

    return Positioned.fill(
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controlsVisible,
          child: Stack(
            children: [
              Positioned(
                left: 14,
                top: 0,
                bottom: 0,
                child: Center(child: button(true)),
              ),
              Positioned(
                right: 14,
                top: 0,
                bottom: 0,
                child: Center(child: button(false)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 弹幕加载结果提示（底部居中，短暂显示）。
  Widget _buildDanmakuToast() {
    return Positioned(
      bottom: _isFullscreen ? 96 : 76,
      left: 24,
      right: 24,
      child: Center(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _danmakuToastText!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
          ),
        ),
      ),
    );
  }

  /// 超分开启状态小药丸：仅随控制栏一起显示，不遮挡观看。
  Widget _buildSuperResPill() {
    return Positioned(
      top: _isFullscreen ? 40 : 36,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        opacity: (_controlsVisible && !_isLocked) ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_awesome,
                      color: Colors.white, size: 12),
                  const SizedBox(width: 4),
                  Text(
                    '超分 · ${_superResMode.label}',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 超分开启/失败的短暂中心徽标（验证用，约 1.8 秒后消失）。
  Widget _buildSuperResBadge() {
    final failed = _superResBadgeText!.contains('失败');
    return Positioned.fill(
      child: Center(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.auto_awesome,
                color: failed ? Colors.redAccent : Colors.white,
                size: 18,
              ),
              const SizedBox(width: 7),
              Text(
                _superResBadgeText!,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrightnessIndicator() {
    return Positioned(
      left: 16.0,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _currentBrightness < 0.5
                    ? Icons.brightness_low
                    : Icons.brightness_high,
                color: Colors.white,
                size: 24,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 100,
                width: 4,
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: _currentBrightness,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${(_currentBrightness * 100).round()}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRightOverlay() {
    if (_showVolumeIndicator && !_isLocked) {
      return Positioned(
        right: 16.0,
        top: 0,
        bottom: 0,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _currentVolume == 0
                      ? Icons.volume_off
                      : _currentVolume < 0.5
                          ? Icons.volume_down
                          : Icons.volume_up,
                  color: Colors.white,
                  size: 24,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 100,
                  width: 4,
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: FractionallySizedBox(
                          heightFactor: _currentVolume,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${(_currentVolume * 100).round()}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      right: 16.0,
      top: 0,
      bottom: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _controlsVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !_controlsVisible,
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _isLocked = !_isLocked;
                  _controlsVisible = true;
                });
                _startHideTimer();
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  _isLocked ? Icons.lock : Icons.lock_open,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹幕手动选择面板：搜番剧 → 选剧集，返回所选剧集。
class _DanmakuPickerSheet extends StatefulWidget {
  final String initialKeyword;

  const _DanmakuPickerSheet({required this.initialKeyword});

  @override
  State<_DanmakuPickerSheet> createState() => _DanmakuPickerSheetState();
}

class _DanmakuPickerSheetState extends State<_DanmakuPickerSheet> {
  late final TextEditingController _controller;
  List<DanmakuAnime> _animes = [];
  List<DanmakuEpisode> _episodes = [];
  DanmakuAnime? _selectedAnime;
  bool _loading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialKeyword);
    if (widget.initialKeyword.trim().isNotEmpty) {
      _search();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _loading = true;
      _selectedAnime = null;
      _episodes = [];
    });
    final results = await DanmakuService.search(keyword);
    if (!mounted) return;
    setState(() {
      _animes = results;
      _loading = false;
      _searched = true;
    });
  }

  Future<void> _pickAnime(DanmakuAnime anime) async {
    setState(() {
      _loading = true;
      _selectedAnime = anime;
    });
    final episodes = await DanmakuService.episodes(anime.animeId);
    if (!mounted) return;
    setState(() {
      _episodes = episodes;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;
    final height = MediaQuery.of(context).size.height * 0.72;
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: false,
                      style: TextStyle(color: fg, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '搜索番剧名',
                        hintStyle: TextStyle(color: sub, fontSize: 14),
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  TextButton(onPressed: _search, child: const Text('搜索')),
                ],
              ),
            ),
            if (_selectedAnime != null)
              ListTile(
                leading: Icon(Icons.arrow_back, color: fg, size: 20),
                title: Text(_selectedAnime!.animeTitle,
                    style: TextStyle(color: fg, fontSize: 14)),
                subtitle: Text('选择剧集',
                    style: TextStyle(color: sub, fontSize: 12)),
                onTap: () => setState(() {
                  _selectedAnime = null;
                  _episodes = [];
                }),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _selectedAnime == null
                      ? (_searched && _animes.isEmpty
                          ? Center(
                              child: Text('没有搜到，换个关键词试试',
                                  style: TextStyle(color: sub)))
                          : ListView.builder(
                              itemCount: _animes.length,
                              itemBuilder: (context, index) {
                                final anime = _animes[index];
                                return ListTile(
                                  title: Text(anime.animeTitle,
                                      style:
                                          TextStyle(color: fg, fontSize: 14)),
                                  subtitle: Text(
                                    [
                                      anime.typeDescription,
                                      if (anime.episodeCount != null)
                                        '共 ${anime.episodeCount} 集',
                                    ].join(' · '),
                                    style:
                                        TextStyle(color: sub, fontSize: 12),
                                  ),
                                  trailing: Icon(Icons.chevron_right,
                                      color: sub, size: 18),
                                  onTap: () => _pickAnime(anime),
                                );
                              },
                            ))
                      : (_episodes.isEmpty
                          ? Center(
                              child: Text('该番剧暂无剧集数据',
                                  style: TextStyle(color: sub)))
                          : ListView.builder(
                              itemCount: _episodes.length,
                              itemBuilder: (context, index) {
                                final episode = _episodes[index];
                                return ListTile(
                                  title: Text(
                                    episode.episodeTitle.isNotEmpty
                                        ? episode.episodeTitle
                                        : '第 ${episode.episodeNumber} 集',
                                    style:
                                        TextStyle(color: fg, fontSize: 14),
                                  ),
                                  onTap: () =>
                                      Navigator.of(context).pop(episode),
                                );
                              },
                            )),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileVideoProgressBar extends StatefulWidget {
  final Player player;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final VoidCallback? onDragUpdate;
  final Function(Duration)? onPositionUpdate;
  final Duration? dragPosition;
  final bool isSeekingViaSwipe;
  final bool live;

  const _MobileVideoProgressBar({
    required this.player,
    this.onDragStart,
    this.onDragEnd,
    this.onDragUpdate,
    this.onPositionUpdate,
    this.dragPosition,
    this.isSeekingViaSwipe = false,
    this.live = false,
  });

  @override
  State<_MobileVideoProgressBar> createState() =>
      _MobileVideoProgressBarState();
}

class _MobileVideoProgressBarState extends State<_MobileVideoProgressBar> {
  bool _isDragging = false;
  double _dragValue = 0.0;
  bool _isSeeking = false; // 新增：标记是否正在 seek
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _bufferSubscription;

  @override
  void initState() {
    super.initState();
    _positionSubscription = widget.player.stream.position.listen((_) {
      if (mounted && !_isDragging && !_isSeeking) {
        setState(() {});
      }
    });
    _bufferSubscription = widget.player.stream.buffer.listen((_) {
      if (mounted && !_isDragging) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _bufferSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.player.state.duration;
    final position = widget.dragPosition ?? widget.player.state.position;

    double value = 0.0;
    if (duration.inMilliseconds > 0) {
      if (widget.live) {
        value = 1.0;
      } else {
        value = position.inMilliseconds / duration.inMilliseconds;
      }
    }

    if (_isDragging && !widget.live) {
      value = _dragValue;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: widget.live
          ? null
          : (details) {
              _isDragging = true;
              widget.onDragStart?.call();
              _updateDrag(details.localPosition.dx, context);
            },
      onHorizontalDragUpdate: widget.live
          ? null
          : (details) {
              if (_isDragging) {
                widget.onDragUpdate?.call();
                _updateDrag(details.localPosition.dx, context);
              }
            },
      onHorizontalDragEnd: widget.live
          ? null
          : (details) async {
              if (_isDragging) {
                final seekPosition = Duration(
                  milliseconds: (_dragValue * duration.inMilliseconds).round(),
                );

                setState(() {
                  _isDragging = false;
                  _isSeeking = true; // 标记开始 seek
                });

                await widget.player.seek(seekPosition);

                // seek 完成后，延迟一小段时间再允许位置更新，确保播放器状态已同步
                await Future.delayed(const Duration(milliseconds: 100));

                if (!mounted) return;
                setState(() {
                  _isSeeking = false; // 标记 seek 完成
                });

                widget.onDragEnd?.call();
              }
            },
      onTapDown: widget.live
          ? null
          : (details) async {
              widget.onDragStart?.call();
              _updateDrag(details.localPosition.dx, context);
              final seekPosition = Duration(
                milliseconds: (_dragValue * duration.inMilliseconds).round(),
              );

              setState(() {
                _isSeeking = true; // 标记开始 seek
              });

              await widget.player.seek(seekPosition);

              // seek 完成后，延迟一小段时间再允许位置更新，确保播放器状态已同步
              await Future.delayed(const Duration(milliseconds: 100));

              if (!mounted) return;
              setState(() {
                _isSeeking = false; // 标记 seek 完成
              });

              widget.onDragEnd?.call();
            },
      child: Container(
        height: 24,
        color: Colors.transparent,
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final progressWidth = constraints.maxWidth;
              final progressValue = value.clamp(0.0, 1.0);
              // 已缓存区间（缓存到的位置 / 总时长）
              double bufferedValue = 0.0;
              if (!widget.live && duration.inMilliseconds > 0) {
                bufferedValue = (widget.player.state.buffer.inMilliseconds /
                        duration.inMilliseconds)
                    .clamp(0.0, 1.0);
                if (bufferedValue < progressValue) {
                  bufferedValue = progressValue;
                }
              }
              final thumbPosition = (progressValue * progressWidth)
                  .clamp(8.0, progressWidth - 8.0);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 9,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                  ),
                  if (bufferedValue > 0)
                    Positioned(
                      left: 0,
                      top: 9,
                      child: Container(
                        width: bufferedValue * progressWidth,
                        height: 6,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: Colors.white.withOpacity(0.55),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    top: 9,
                    child: Container(
                      width: progressValue * progressWidth,
                      height: 6,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        color: Colors.red,
                      ),
                    ),
                  ),
                  if (!widget.live)
                    Positioned(
                      left: thumbPosition - 8,
                      top: 4,
                      child: AnimatedScale(
                        scale: widget.isSeekingViaSwipe ? 1.25 : 1.0,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.red,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.3),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _updateDrag(double dx, BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final width = box.size.width;
    final value = (dx / width).clamp(0.0, 1.0);
    setState(() => _dragValue = value);
    if (!widget.live) {
      final duration = widget.player.state.duration;
      final position =
          Duration(milliseconds: (value * duration.inMilliseconds).round());
      widget.onPositionUpdate?.call(position);
    }
  }
}
