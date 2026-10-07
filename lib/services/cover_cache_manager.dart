import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'user_data_service.dart';

/// 封面图片缓存管理器（带服务端代理兜底）。
///
/// 里世界（特殊模式）下，不少特殊源的封面图床对直连很不友好（连接被
/// 重置、防盗链、裸 IP 非标端口等），而同一张图由 MoonTVPlus 服务器
/// 抓取则畅通（网页版正是服务端取图）。因此这里给图片下载加一层兜底：
/// 直连以任何形式失败（连接异常或 HTTP 错误状态）时，自动改走用户自己
/// Plus 服务器的 /api/image-proxy 中转（带登录 Cookie，服务端中间件
/// 要求登录态），取到的图片仍按原始 URL 存入缓存，上层无感知。
/// 普通模式下不启用兜底，行为与默认缓存管理器一致。
class CoverCacheManager extends CacheManager with ImageCacheManager {
  static final CoverCacheManager instance = CoverCacheManager._();

  factory CoverCacheManager() => instance;

  CoverCacheManager._()
      : super(
          Config(
            'seleneAllCoverCache',
            stalePeriod: const Duration(days: 30),
            maxNrOfCacheObjects: 1000,
            fileService: ProxyFallbackFileService(),
          ),
        );
}

/// 先直连、失败后经服务端图片代理重试的文件服务。
class ProxyFallbackFileService extends HttpFileService {
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      return await super.get(url, headers: headers);
    } catch (directError) {
      final proxy = await _buildProxyRequest(url);
      if (proxy == null) {
        rethrow;
      }
      return await super.get(proxy.url, headers: proxy.headers);
    }
  }

  /// 构造代理请求；不适用（非特殊模式 / 非远程图 / 已是代理地址 /
  /// 就是服务器自身地址 / 未配置服务器）时返回 null。
  static Future<({String url, Map<String, String> headers})?>
      _buildProxyRequest(String directUrl) async {
    try {
      if (!await UserDataService.getSpecialMode()) return null;
      if (directUrl.contains('/api/image-proxy')) return null;
      final uri = Uri.tryParse(directUrl);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        return null;
      }
      final serverUrl = await UserDataService.getServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) return null;
      final serverUri = Uri.tryParse(serverUrl);
      if (serverUri != null && uri.host == serverUri.host) return null;
      final base = serverUrl.replaceAll(RegExp(r'/+$'), '');
      final proxyUrl =
          '$base/api/image-proxy?url=${Uri.encodeComponent(directUrl)}';
      final cookies = await UserDataService.getCookies();
      final headers = <String, String>{
        if (cookies != null && cookies.isNotEmpty) 'Cookie': cookies,
      };
      return (url: proxyUrl, headers: headers);
    } catch (_) {
      return null;
    }
  }
}
