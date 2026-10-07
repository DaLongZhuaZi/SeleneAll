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

/// 把 Anime4K 着色器应用到 media_kit 播放器（mpv `glsl-shaders` 属性）。
class SuperResService {
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

  /// 应用超分模式到播放器；off 时清空着色器链。失败只记日志不抛。
  static Future<void> apply(Player player, SuperResMode mode) async {
    try {
      final platform = player.platform;
      if (platform is! NativePlayer) return;
      if (mode == SuperResMode.off) {
        await platform.setProperty('glsl-shaders', '');
        return;
      }
      final dir = await _ensureExtracted();
      final separator = Platform.isWindows ? ';' : ':';
      final paths =
          _chains[mode]!.map((name) => '${dir.path}/$name').join(separator);
      await platform.setProperty('glsl-shaders', paths);
    } catch (e) {
      debugPrint('SuperResService.apply failed: $e');
    }
  }
}
