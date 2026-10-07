import 'api_service.dart';
import 'user_data_service.dart';

/// MoonTVPlus 特殊源（“里世界”）支持服务。
///
/// 服务端约定（MoonTVPlus 的双向隔离）：
/// - /api/search、/api/search/ws、/api/detail、/api/source-detail、
///   /api/source-search/* 等接口在带 `special=1` 查询参数时只处理特殊源，
///   不带时只处理普通源；
/// - 收藏与播放记录接口返回全部数据，客户端需按当前模式自行过滤，
///   与网页端 filterRecordsBySpecialSourceContext 的口径一致。
class SpecialSourceService {
  static Set<String>? _cachedKeys;
  static List<Map<String, dynamic>>? _cachedSources;
  static String? _cachedForServer;

  /// 里世界模式是否开启
  static Future<bool> isSpecialMode() async {
    return await UserDataService.getSpecialMode();
  }

  /// 清除特殊源 key 缓存（切换服务器或退出登录时调用）
  static void clearCache() {
    _cachedKeys = null;
    _cachedSources = null;
    _cachedForServer = null;
  }

  /// 获取特殊源完整列表（每项含 key、name 等字段）。
  ///
  /// 通过 /api/source-search/sources?special=1 拉取（该接口在 special=1 时
  /// 只返回特殊源）。结果按服务器地址缓存；拉取失败时返回上次缓存或空列表。
  static Future<List<Map<String, dynamic>>> getSpecialSources({
    bool forceRefresh = false,
  }) async {
    final server = await UserDataService.getServerUrl();
    if (!forceRefresh && _cachedSources != null && _cachedForServer == server) {
      return _cachedSources!;
    }
    try {
      // 该接口返回 {"sources": [...]} 结构
      final response = await ApiService.get<Map<String, dynamic>>(
        '/api/source-search/sources',
        queryParameters: {'special': '1'},
        fromJson: (data) => data as Map<String, dynamic>,
      );
      if (response.success && response.data != null) {
        final list = response.data!['sources'];
        final sources = <Map<String, dynamic>>[];
        if (list is List) {
          for (final item in list) {
            if (item is Map<String, dynamic>) {
              sources.add(item);
            }
          }
        }
        _cachedSources = sources;
        _cachedKeys = {
          for (final s in sources)
            if (s['key'] is String && (s['key'] as String).isNotEmpty)
              s['key'] as String,
        };
        _cachedForServer = server;
        return sources;
      }
    } catch (_) {
      // 静默失败：返回缓存或空列表
    }
    return _cachedSources ?? <Map<String, dynamic>>[];
  }

  /// 获取特殊源 key 集合（与 [getSpecialSources] 共用同一次拉取与缓存）。
  static Future<Set<String>> getSpecialSourceKeys({
    bool forceRefresh = false,
  }) async {
    final server = await UserDataService.getServerUrl();
    if (forceRefresh || _cachedKeys == null || _cachedForServer != server) {
      await getSpecialSources(forceRefresh: forceRefresh);
    }
    return _cachedKeys ?? <String>{};
  }

  /// 按当前模式过滤带 source 字段的条目列表。
  ///
  /// - 普通模式：排除特殊源条目；
  /// - 里世界模式：只保留特殊源条目；
  /// - 本地模式或服务端没有特殊源时：普通模式原样返回，
  ///   里世界模式返回空（与网页端行为一致）。
  static Future<List<T>> filterByMode<T>(
    List<T> items,
    String Function(T item) sourceOf,
  ) async {
    final isLocalMode = await UserDataService.getIsLocalMode();
    if (isLocalMode) {
      return items;
    }
    final specialMode = await isSpecialMode();
    final keys = await getSpecialSourceKeys();
    if (keys.isEmpty) {
      return specialMode ? <T>[] : items;
    }
    return items
        .where((item) => keys.contains(sourceOf(item)) == specialMode)
        .toList();
  }
}
