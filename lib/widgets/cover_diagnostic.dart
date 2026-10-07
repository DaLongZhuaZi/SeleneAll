import 'dart:io';

import 'package:flutter/material.dart';

import '../services/cover_cache_manager.dart';
import '../utils/image_url.dart';

/// 封面加载诊断：在 App 内用三种方式实测同一张封面图，把确切结果
/// （状态码/字节数/异常原文）显示出来，用于定位封面不显示的真实原因。
/// 1) dart:io 原始请求（无附加头） 2) 带 App 图片请求头的原始请求
/// 3) CachedNetworkImage 实际使用的缓存管理器加载
class CoverDiagnostic {
  static Future<void> show(BuildContext context, String imageUrl) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('诊断中…'),
          ],
        ),
      ),
    );

    final report = await _run(imageUrl);

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('封面诊断结果'),
        content: SingleChildScrollView(
          child: SelectableText(
            report,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static Future<String> _run(String imageUrl) async {
    final buffer = StringBuffer();
    buffer.writeln('URL: $imageUrl');
    buffer.writeln();

    // 1) 原始请求（复刻 VideoCard 的 URL 处理，但不带任何附加头）
    final resolved = await getImageUrl(imageUrl, null);
    buffer.writeln('处理后 URL: $resolved');
    await _testRaw(buffer, '原始请求(无头)', resolved, null);

    // 2) 带 App 当前图片请求头
    final headers = getImageRequestHeaders(resolved, null);
    buffer.writeln('App 请求头: $headers');
    await _testRaw(buffer, '原始请求(带头)', resolved, headers);

    // 3) 缓存管理器（CachedNetworkImage 的实际加载路径，含代理兜底）
    try {
      final file = await CoverCacheManager.instance.getSingleFile(
        resolved,
        headers: headers,
      );
      final length = await file.length();
      buffer.writeln('[缓存加载] 成功: $length 字节');
    } catch (e) {
      buffer.writeln('[缓存加载] 失败: $e');
    }
    return buffer.toString();
  }

  static Future<void> _testRaw(
    StringBuffer buffer,
    String label,
    String url,
    Map<String, String>? headers,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      headers?.forEach((k, v) => request.headers.set(k, v));
      final response = await request.close();
      final bytes = await response.fold<int>(0, (sum, data) => sum + data.length);
      buffer.writeln(
        '[$label] 状态 ${response.statusCode}, $bytes 字节, '
        'contentType=${response.headers.contentType}',
      );
    } catch (e) {
      buffer.writeln('[$label] 异常: $e');
    } finally {
      client.close(force: true);
    }
  }
}
