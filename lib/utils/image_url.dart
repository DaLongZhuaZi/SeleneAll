// 通用图片地址处理工具
import '../services/user_data_service.dart';

/// 根据来源处理图片 URL（例如豆瓣域名替换）。
/// - [originalUrl]: 原始图片地址
/// - [source]: 数据来源（如 'douban'、'bangumi' 等）
/// 返回可直接用于加载的图片地址。
Future<String> getImageUrl(String originalUrl, String? source) async {
  if (source == 'douban' && originalUrl.isNotEmpty) {
    final imageSourceKey = await UserDataService.getDoubanImageSourceKey();
    
    switch (imageSourceKey) {
      case 'official_cdn':
        return originalUrl.replaceAll(
          RegExp(r'img\d+\.doubanio\.com'),
          'img3.doubanio.com',
        );
      case 'cdn_tencent':
        return originalUrl.replaceAll(
          RegExp(r'img\d+\.doubanio\.com'),
          'img.doubanio.cmliussss.net',
        );
      case 'cdn_aliyun':
        return originalUrl.replaceAll(
          RegExp(r'img\d+\.doubanio\.com'),
          'img.doubanio.cmliussss.com',
        );
      case 'direct':
      default:
        return originalUrl;
    }
  }
  return originalUrl;
}

/// 返回加载网络图片所需的 HTTP 头（主要用于绕过特定站点的反盗链）。
/// - 豆瓣来源：带豆瓣 Referer 与浏览器 UA；
/// - 其他远程来源（里世界特殊源的封面大多来自各源站自有图床/CDN）：这类站点
///   常按 UA / Referer 防盗链，Dart 默认 UA 会被直接拒绝，而网页版用浏览器
///   条件加载正常——因此统一带浏览器 UA，并以图片自身域名为 Referer 对齐
///   网页版的加载条件。
Map<String, String>? getImageRequestHeaders(String imageUrl, String? source) {
  final bool isDoubanSource = (source == 'douban') ||
      RegExp(r'https?://([^/]+\.)?douban(io|)\.com', caseSensitive: false)
          .hasMatch(imageUrl);

  const browserUa =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
  const accept = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';

  if (isDoubanSource) {
    // 常见可用的 Referer 和 UA，避免 403 或 Android 解码失败
    return <String, String>{
      'Referer': 'https://movie.douban.com/',
      'User-Agent': browserUa,
      'Accept': accept,
    };
  }

  final uri = Uri.tryParse(imageUrl);
  if (uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty) {
    return <String, String>{
      'Referer': '${uri.scheme}://${uri.host}/',
      'User-Agent': browserUa,
      'Accept': accept,
    };
  }
  return null;
}


