import '../models/search_result.dart';
import 'api_service.dart';

/// 源分类（MoonTVPlus /api/source-search/categories 返回项）。
class SourceCategory {
  final String id;
  final String name;

  /// 父分类 id，一级分类为 '0'。
  final String pid;

  const SourceCategory({
    required this.id,
    required this.name,
    required this.pid,
  });

  factory SourceCategory.fromJson(Map<String, dynamic> json) {
    return SourceCategory(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      pid: json['pid']?.toString() ?? '0',
    );
  }
}

/// 源分类下的一页视频（/api/source-search/videos 返回）。
class SourceVideoPage {
  final List<SearchResult> results;
  final int total;
  final int page;
  final int pageCount;

  const SourceVideoPage({
    required this.results,
    required this.total,
    required this.page,
    required this.pageCount,
  });
}

/// 按源浏览内容：分类列表 + 分类下分页视频。
/// 特殊模式下 ApiService 会自动给 /api/source-search/* 附加 special=1，
/// 里世界与普通模式（如后续接入）都可直接复用。
class SourceBrowseService {
  static Future<List<SourceCategory>> getCategories(String sourceKey) async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/source-search/categories',
      queryParameters: {'source': sourceKey},
      fromJson: (json) => json as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      throw Exception(response.message ?? '获取分类失败');
    }
    final list = response.data!['categories'];
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SourceCategory.fromJson)
        .where((c) => c.id.isNotEmpty)
        .toList();
  }

  static Future<SourceVideoPage> getVideos(
    String sourceKey,
    String categoryId,
    int page,
  ) async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/source-search/videos',
      queryParameters: {
        'source': sourceKey,
        'categoryId': categoryId,
        'page': page.toString(),
      },
      fromJson: (json) => json as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) {
      throw Exception(response.message ?? '获取视频列表失败');
    }
    final data = response.data!;
    final list = data['results'];
    final results = <SearchResult>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          results.add(SearchResult.fromJson(item));
        }
      }
    }
    return SourceVideoPage(
      results: results,
      total: (data['total'] as num?)?.toInt() ?? 0,
      page: (data['page'] as num?)?.toInt() ?? page,
      pageCount: (data['pageCount'] as num?)?.toInt() ?? 0,
    );
  }
}
