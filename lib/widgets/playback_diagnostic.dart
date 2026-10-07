import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/user_data_service.dart';

/// 播放诊断：用 App 播放时实际构造的中转地址，在手机上分段实测
/// 「列表中转 → 首个分片 → 原始直连对照」，把每一环的状态码、耗时
/// 和服务端错误原文显示出来，用于定位全中转播放卡死断在哪一环。
Future<void> showPlaybackDiagnostic(
  BuildContext context, {
  required String rawUrl,
  required String sourceKey,
}) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      title: Text('播放诊断'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text('正在分段实测…'),
        ],
      ),
    ),
  );

  final lines = await _runPlaybackDiagnostic(rawUrl, sourceKey);

  if (!context.mounted) return;
  Navigator.of(context).pop();
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('播放诊断结果'),
      content: SingleChildScrollView(
        child: SelectableText(
          lines.join('\n'),
          style: const TextStyle(fontSize: 12.5, height: 1.5),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Future<String> _fetchPreview(
  String url,
  Map<String, String> headers, {
  int maxBytes = 300000,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  try {
    final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
    headers.forEach((k, v) => request.headers.set(k, v));
    final response = await request.close().timeout(timeout);
    final builder = BytesBuilder();
    await for (final chunk in response.timeout(timeout)) {
      builder.add(chunk);
      if (builder.length >= maxBytes) break;
    }
    final body = utf8.decode(builder.toBytes(), allowMalformed: true);
    return 'HTTP ${response.statusCode} · ${builder.length}B\n$body';
  } finally {
    client.close(force: true);
  }
}

Future<List<String>> _runPlaybackDiagnostic(
  String rawUrl,
  String sourceKey,
) async {
  final lines = <String>[];
  final serverUrl = await UserDataService.getServerUrl();
  final cookies = await UserDataService.getCookies();
  lines.add('源 key：$sourceKey');
  lines.add('原始地址 host：${Uri.tryParse(rawUrl)?.host ?? rawUrl}');
  lines.add('Cookie：${cookies != null && cookies.isNotEmpty ? '有（${cookies.length} 字符）' : '无'}');
  if (serverUrl == null || serverUrl.isEmpty) {
    lines.add('未配置服务器地址，无法测试中转');
    return lines;
  }
  final base = serverUrl.replaceAll(RegExp(r'/+$'), '');
  final authHeaders = <String, String>{
    if (cookies != null && cookies.isNotEmpty) 'Cookie': cookies,
  };
  final proxyUrl =
      '$base/api/proxy-m3u8?url=${Uri.encodeComponent(rawUrl)}&source=${Uri.encodeComponent(sourceKey)}&proxySegments=true';

  // ① 列表中转（App 实际用的地址）
  String? firstSegmentUrl;
  var segmentsRewritten = false;
  final sw1 = Stopwatch()..start();
  try {
    final result = await _fetchPreview(proxyUrl, authHeaders);
    sw1.stop();
    final splitAt = result.indexOf('\n');
    final head = result.substring(0, splitAt);
    final body = result.substring(splitAt + 1);
    lines.add('');
    lines.add('① 列表中转：$head · ${sw1.elapsedMilliseconds}ms');
    if (!head.startsWith('HTTP 200')) {
      lines.add('   返回内容：${body.trim().take(220)}');
      return lines;
    }
    segmentsRewritten = body.contains('/api/proxy/vod/segment');
    lines.add('   分片已改写为中转地址：${segmentsRewritten ? '是' : '否'}');
    for (final line in body.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty && !t.startsWith('#')) {
        firstSegmentUrl =
            Uri.tryParse(proxyUrl)?.resolve(t).toString() ?? t;
        break;
      }
    }
    if (firstSegmentUrl == null) {
      lines.add('   列表里没找到可播条目（可能是主列表，需再下一层）');
      // 主列表：取第一条子列表再请求一次
      return lines;
    }
  } catch (e) {
    lines.add('');
    lines.add('① 列表中转失败：$e');
    return lines;
  }

  // ② 首个分片（或子列表下一层）
  final sw2 = Stopwatch()..start();
  try {
    final isPlaylist = firstSegmentUrl!.contains('.m3u8') ||
        firstSegmentUrl!.contains('proxy-m3u8');
    final result = await _fetchPreview(
      firstSegmentUrl!,
      authHeaders,
      maxBytes: isPlaylist ? 300000 : 8192,
    );
    sw2.stop();
    final splitAt = result.indexOf('\n');
    final head = result.substring(0, splitAt);
    final body = result.substring(splitAt + 1);
    lines.add('');
    lines.add(
        '② ${isPlaylist ? '子列表' : '首个分片'}：$head · ${sw2.elapsedMilliseconds}ms');
    if (!head.startsWith('HTTP 200')) {
      lines.add('   错误内容：${body.trim().take(220)}');
    } else if (isPlaylist) {
      // 再下一层拿真正的分片测
      String? seg;
      for (final line in body.split('\n')) {
        final t = line.trim();
        if (t.isNotEmpty && !t.startsWith('#')) {
          seg = Uri.tryParse(firstSegmentUrl!)?.resolve(t).toString() ?? t;
          break;
        }
      }
      if (seg != null) {
        final sw3 = Stopwatch()..start();
        final segResult =
            await _fetchPreview(seg, authHeaders, maxBytes: 8192);
        sw3.stop();
        final segHead = segResult.substring(0, segResult.indexOf('\n'));
        lines.add(
            '③ 首个分片：$segHead · ${sw3.elapsedMilliseconds}ms');
        if (!segHead.startsWith('HTTP 200')) {
          final segBody =
              segResult.substring(segResult.indexOf('\n') + 1);
          lines.add('   错误内容：${segBody.trim().take(220)}');
        }
      }
    }
  } catch (e) {
    lines.add('');
    lines.add('② 分片测试失败：$e');
  }

  // 直连对照
  final sw4 = Stopwatch()..start();
  try {
    final result =
        await _fetchPreview(rawUrl, const {}, maxBytes: 60000);
    sw4.stop();
    final head = result.substring(0, result.indexOf('\n'));
    lines.add('');
    lines.add('对照 原始列表直连：$head · ${sw4.elapsedMilliseconds}ms');
  } catch (e) {
    lines.add('');
    lines.add('对照 原始列表直连失败：$e');
  }
  return lines;
}

extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
