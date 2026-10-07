import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

/// 播放器超分模式（Anime4K）。
/// 与网页端超分同算法：Anime4K 的 mpv GLSL 着色器链。
enum SuperResMode {
  off,
  fast,
  balanced,
  quality;

  String get label => switch (this) {
        SuperResMode.off => '关闭',
        SuperResMode.fast => '快速',
        SuperResMode.balanced => '均衡',
        SuperResMode.quality => '高质量',
      };

  String get description => switch (this) {
        SuperResMode.off => '不做超分处理',
        SuperResMode.fast => '小模型链，功耗低，老设备/高分辨率源优先',
        SuperResMode.balanced => 'Anime4K 模式 B，中等功耗',
        SuperResMode.quality => 'Anime4K 模式 A，效果最好，功耗最高',
      };

  static SuperResMode fromName(String? name) {
    for (final mode in SuperResMode.values) {
      if (mode.name == name) return mode;
    }
    return SuperResMode.off;
  }
}

/// 一次超分应用的可验证结果：着色器链是否真的写进了 mpv 并被读回，
/// 以及 mpv 日志里是否出现着色器编译错误。UI 用它给用户明确反馈。
class SuperResStatus {
  final SuperResMode mode;

  /// 从 mpv 读回的 glsl-shaders 条数（0 表示未生效/已关闭）。
  final int shaderCount;

  /// mpv 日志中捕获到的着色器相关错误（编译失败等），无则为 null。
  final String? error;

  const SuperResStatus({
    required this.mode,
    required this.shaderCount,
    this.error,
  });

  bool get active => mode != SuperResMode.off && shaderCount > 0;
}

/// 把 Anime4K 着色器应用到 media_kit 播放器（mpv `glsl-shaders` 属性）。
class SuperResService {
  /// 最近一次 apply 的结果（供 UI 显示验证状态）。
  static SuperResStatus? lastStatus;
  /// 各模式的着色器链。balanced = Anime4K 官方 mpv 预设 Mode B，
  /// quality = Mode A；fast 为只用 S 号 CNN 的裁剪链。
  static const Map<SuperResMode, List<String>> _chains = {
    SuperResMode.fast: [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_S.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    SuperResMode.balanced: [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_Soft_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ],
    SuperResMode.quality: [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
      'Anime4K_AutoDownscalePre_x4.glsl',
      'Anime4K_Upscale_CNN_x2_S.glsl',
    ],
  };

  static Directory? _shaderDir;

  /// 把 assets 里的着色器解压到应用支持目录（mpv 需要真实文件路径）。
  static Future<Directory> _ensureExtracted() async {
    final cached = _shaderDir;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/anime4k');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final names = _chains.values.expand((chain) => chain).toSet();
    for (final name in names) {
      final file = File('${dir.path}/$name');
      if (!await file.exists()) {
        final data = await rootBundle.load('assets/anime4k/$name');
        await file.writeAsBytes(data.buffer.asUint8List());
      }
    }
    _shaderDir = dir;
    return dir;
  }

  /// 应用超分模式到播放器；off 时清空着色器链。
  /// 应用后回读 mpv 的 glsl-shaders 属性核对条数，并短暂监听 mpv 日志
  /// 捕获着色器编译错误，结果存入 [lastStatus] 供 UI 展示。失败不抛。
  static Future<void> apply(Player player, SuperResMode mode) async {
    try {
      final platform = player.platform;
      if (platform is! NativePlayer) return;
      if (mode == SuperResMode.off) {
        await platform.setProperty('glsl-shaders', '');
        lastStatus = const SuperResStatus(
          mode: SuperResMode.off,
          shaderCount: 0,
        );
        return;
      }
      final dir = await _ensureExtracted();
      final separator = Platform.isWindows ? ';' : ':';
      final paths =
          _chains[mode]!.map((name) => '${dir.path}/$name').join(separator);

      // 监听 mpv 日志，抓着色器编译/加载错误（mpv 对坏着色器只记日志、
      // 不报错，画面看起来就像没开——这是验证超分是否真生效的关键证据）。
      String? shaderError;
      final logSub = player.stream.log.listen((log) {
        final text = log.text.toLowerCase();
        if (text.contains('shader') || text.contains('glsl')) {
          if (log.level == 'error' ||
              log.level == 'warn' ||
              text.contains('fail') ||
              text.contains('error')) {
            shaderError ??= log.text.trim();
          }
        }
      });

      await platform.setProperty('glsl-shaders', paths);

      // 回读核对：属性里确实挂上了着色器才算应用成功。
      var readBackCount = 0;
      try {
        final readBack = await platform.getProperty('glsl-shaders');
        readBackCount =
            readBack.split(separator).where((s) => s.trim().isNotEmpty).length;
      } catch (_) {}

      lastStatus = SuperResStatus(
        mode: mode,
        shaderCount: readBackCount,
      );

      // 着色器是首次渲染时才编译的，错误日志稍后才到——延迟收取一次。
      Future.delayed(const Duration(seconds: 3), () async {
        await logSub.cancel();
        if (shaderError != null && lastStatus?.mode == mode) {
          lastStatus = SuperResStatus(
            mode: mode,
            shaderCount: readBackCount,
            error: shaderError,
          );
        }
      });
    } catch (e) {
      debugPrint('SuperResService.apply failed: $e');
      lastStatus = SuperResStatus(
        mode: mode,
        shaderCount: 0,
        error: '$e',
      );
    }
  }
}
