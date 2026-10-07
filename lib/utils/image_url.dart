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
/// - 其他远程来源（里世界特殊源的封面大多来自各源站自有图床/CDN）：网页版
///   VideoCard 用 referrerPolicy='no-referrer' 加载，即浏览器 UA + 完全不发
///   Referer。这类图床的防盗链白名单只放行空 Referer（外加拒绝非浏览器 UA）：
///   Dart 默认 UA 会被拒，带任何外域 Referer（含图片自身域名）同样被拒——
///   因此这里只给浏览器 UA，绝不附加 Referer。
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
    // 注意：绝不能带 Referer——见上方说明，带任何外域 Referer 都会被
    // 特殊源图床的防盗链拒绝（网页版同理用 no-referrer）。
    return <String, String>{
      'User-Agent': browserUa,
      'Accept': accept,
    };
  }
  return null;
}


