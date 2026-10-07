import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';

import '../services/danmaku_service.dart';

/// 弹幕渲染层：轨道式滚动弹幕 + 顶部/底部静态弹幕。
///
/// 时间模型：以播放器 position 流为锚，帧间用本地时钟按倍速推进；
/// 与锚点偏差过大（seek/缓冲结束）时吸附并重建轨道。缓冲与暂停时冻结。
class DanmakuLayer extends StatefulWidget {
  final Player player;
  final List<DanmakuItem> items; // 已按 time 升序
  final double opacity; // 0.3 - 1.0
  final double fontScale; // 字号倍率
  final double areaRatio; // 滚动区占画面高度比例

  const DanmakuLayer({
    super.key,
    required this.player,
    required this.items,
    required this.opacity,
    required this.fontScale,
    required this.areaRatio,
  });

  @override
  State<DanmakuLayer> createState() => _DanmakuLayerState();
}

class _Running {
  final DanmakuItem item;
  final int lane; // 滚动轨道号；静态弹幕为 -1
  final double spawnTime; // 出现时的视频时间（秒）
  final TextPainter painter;
  final double width;

  _Running({
    required this.item,
    required this.lane,
    required this.spawnTime,
    required this.painter,
    required this.width,
  });
}

class _DanmakuLayerState extends State<DanmakuLayer>
    with SingleTickerProviderStateMixin {
  static const double _baseFontSize = 15.5;
  static const double _traverseSeconds = 7.0; // 弹幕横穿屏幕用时
  static const double _staticSeconds = 4.5; // 顶部/底部弹幕停留
  static const double _laneGap = 18.0; // 同轨道前后弹幕最小间距(px)

  late final Ticker _ticker;
  final List<StreamSubscription> _subs = [];
  final ValueNotifier<int> _frame = ValueNotifier(0);

  double _videoTime = 0;
  Duration _lastTick = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  double _rate = 1.0;
  int _pointer = 0;
  Size _size = Size.zero;

  final List<_Running> _scrolling = [];
  final List<_Running> _statics = [];
  List<double> _laneReadyAt = [];

  double get _fontSize => _baseFontSize * widget.fontScale;
  double get _laneHeight => _fontSize + 9;

  @override
  void initState() {
    super.initState();
    _videoTime = widget.player.state.position.inMilliseconds / 1000.0;
    _playing = widget.player.state.playing;
    _rate = widget.player.state.rate;
    _resetPointer();
    _subs.add(widget.player.stream.position.listen((pos) {
      final t = pos.inMilliseconds / 1000.0;
      // 与本地时钟偏差大 = 发生了 seek/跳转：吸附并重建
      if ((t - _videoTime).abs() > 1.6) {
        _videoTime = t;
        _clearRunning();
        _resetPointer();
      } else if ((t - _videoTime).abs() > 0.35) {
        _videoTime = t; // 小偏差直接对齐锚点
      }
    }));
    _subs.add(widget.player.stream.playing.listen((v) => _playing = v));
    _subs.add(widget.player.stream.buffering.listen((v) => _buffering = v));
    _subs.add(widget.player.stream.rate.listen((v) => _rate = v));
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didUpdateWidget(covariant DanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.items, widget.items)) {
      _videoTime = widget.player.state.position.inMilliseconds / 1000.0;
      _clearRunning();
      _resetPointer();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    for (final sub in _subs) {
      sub.cancel();
    }
    _clearRunning();
    _frame.dispose();
    super.dispose();
  }

  void _resetPointer() {
    // 二分找第一个 time >= 当前时间的弹幕
    var lo = 0;
    var hi = widget.items.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (widget.items[mid].time < _videoTime) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _pointer = lo;
  }

  void _clearRunning() {
    for (final r in _scrolling) {
      r.painter.dispose();
    }
    for (final r in _statics) {
      r.painter.dispose();
    }
    _scrolling.clear();
    _statics.clear();
    _laneReadyAt = [];
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMilliseconds / 1000.0;
    _lastTick = elapsed;
    if (dt <= 0 || dt > 0.5) {
      _frame.value++;
      return;
    }
    if (_playing && !_buffering && _size != Size.zero) {
      _videoTime += dt * _rate;
      _spawnDue();
    }
    _cullExited();
    _frame.value++;
  }

  double get _speedPx =>
      _size.width <= 0 ? 0 : _size.width / _traverseSeconds;

  int get _laneCount {
    if (_size.height <= 0) return 0;
    return math.max(1, (_size.height * widget.areaRatio) ~/ _laneHeight);
  }

  void _spawnDue() {
    var spawned = 0;
    while (_pointer < widget.items.length &&
        widget.items[_pointer].time <= _videoTime &&
        spawned < 12) {
      final item = widget.items[_pointer++];
      spawned++;
      _spawn(item);
    }
    // 指针落后太多（长时间卡顿后）直接跳过积压，避免弹幕洪峰
    while (_pointer < widget.items.length &&
        widget.items[_pointer].time < _videoTime - 1.0) {
      _pointer++;
    }
  }

  TextPainter _measure(DanmakuItem item) {
    final painter = TextPainter(
      text: TextSpan(
        text: item.text,
        style: TextStyle(
          fontSize: _fontSize,
          color: Color(0xFF000000 | (item.color & 0xFFFFFF)),
          shadows: const [
            Shadow(color: Colors.black87, offset: Offset(1, 0)),
            Shadow(color: Colors.black87, offset: Offset(-1, 0)),
            Shadow(color: Colors.black87, offset: Offset(0, 1)),
            Shadow(color: Colors.black87, offset: Offset(0, -1)),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter;
  }

  void _spawn(DanmakuItem item) {
    if (item.mode == 4 || item.mode == 5) {
      // 静态弹幕（顶/底）：同类最多同时 2 条
      final sameKind =
          _statics.where((r) => r.item.mode == item.mode).length;
      if (sameKind >= 2) return;
      final painter = _measure(item);
      _statics.add(_Running(
        item: item,
        lane: -1,
        spawnTime: _videoTime,
        painter: painter,
        width: painter.width,
      ));
      return;
    }
    // 滚动弹幕：找一条已空出的轨道
    final lanes = _laneCount;
    if (lanes == 0) return;
    if (_laneReadyAt.length != lanes) {
      _laneReadyAt = List.filled(lanes, 0);
    }
    final v = _speedPx;
    if (v <= 0) return;
    for (var lane = 0; lane < lanes; lane++) {
      if (_videoTime >= _laneReadyAt[lane]) {
        final painter = _measure(item);
        _scrolling.add(_Running(
          item: item,
          lane: lane,
          spawnTime: _videoTime,
          painter: painter,
          width: painter.width,
        ));
        // 本条尾部完全进入屏幕后，该轨道才可再发
        _laneReadyAt[lane] = _videoTime + (painter.width + _laneGap) / v;
        return;
      }
    }
    // 无空轨道：丢弃（与主流播放器一致，避免重叠）
  }

  void _cullExited() {
    final v = _speedPx;
    _scrolling.removeWhere((r) {
      final x = _size.width - v * (_videoTime - r.spawnTime);
      final gone = x + r.width < -8;
      if (gone) r.painter.dispose();
      return gone;
    });
    _statics.removeWhere((r) {
      final gone = _videoTime - r.spawnTime > _staticSeconds;
      if (gone) r.painter.dispose();
      return gone;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _size = Size(constraints.maxWidth, constraints.maxHeight);
        return IgnorePointer(
          child: CustomPaint(
            size: _size,
            painter: _DanmakuPainter(
              repaint: _frame,
              scrolling: _scrolling,
              statics: _statics,
              videoTime: () => _videoTime,
              speedPx: () => _speedPx,
              laneHeight: _laneHeight,
              fontSize: _fontSize,
              opacity: widget.opacity,
              size: () => _size,
            ),
          ),
        );
      },
    );
  }
}

class _DanmakuPainter extends CustomPainter {
  final List<_Running> scrolling;
  final List<_Running> statics;
  final double Function() videoTime;
  final double Function() speedPx;
  final double laneHeight;
  final double fontSize;
  final double opacity;
  final Size Function() size;

  _DanmakuPainter({
    required Listenable repaint,
    required this.scrolling,
    required this.statics,
    required this.videoTime,
    required this.speedPx,
    required this.laneHeight,
    required this.fontSize,
    required this.opacity,
    required this.size,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final t = videoTime();
    final v = speedPx();
    final sz = size();
    if (v <= 0 || sz == Size.zero) return;
    canvas.saveLayer(
      Offset.zero & canvasSize,
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
    );
    for (final r in scrolling) {
      final x = sz.width - v * (t - r.spawnTime);
      if (x > sz.width || x + r.width < -8) continue;
      final y = 6 + r.lane * laneHeight;
      r.painter.paint(canvas, Offset(x, y));
    }
    var topIndex = 0;
    var bottomIndex = 0;
    for (final r in statics) {
      final x = (sz.width - r.width) / 2;
      double y;
      if (r.item.mode == 5) {
        y = 6 + (topIndex++) * laneHeight;
      } else {
        y = sz.height - fontSize - 10 - (bottomIndex++) * laneHeight;
      }
      r.painter.paint(canvas, Offset(x, y.clamp(0, sz.height)));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) => true;
}
