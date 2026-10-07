import 'api_service.dart';

/// 一条弹幕（由服务端返回的 B 站风格 p 属性解析而来）。
class DanmakuItem {
  /// 出现时间（秒）
  final double time;

  final String text;

  /// 类型：1 滚动、4 底部、5 顶部（其余按滚动处理）
  final int mode;

  /// 颜色（RGB 整数），白色为 16777215
  final int color;

  const DanmakuItem({
    required this.time,
    required this.text,
    required this.mode,
    required this.color,
  });

  factory DanmakuItem.fromJson(Map<String, dynamic> json) {
    final p = (json['p'] as String? ?? '').split(',');
    final time = p.isNotEmpty ? double.tryParse(p[0]) ?? 0 : 0.0;
    final mode = p.length > 1 ? int.tryParse(p[1]) ?? 1 : 1;
    final color = p.length > 3 ? int.tryParse(p[3]) ?? 16777215 : 16777215;
    return DanmakuItem(
      time: time,
      text: json['m'] as String? ?? '',
      mode: mode,
      color: color,
    );
  }
}

/// 自动匹配到的一集（dandanplay 匹配结果）。
class DanmakuMatch {
  final int episodeId;
  final int animeId;
  final String animeTitle;
  final String episodeTitle;

  const DanmakuMatch({
    required this.episodeId,
    required this.animeId,
    required this.animeTitle,
    required this.episodeTitle,
  });

  factory DanmakuMatch.fromJson(Map<String, dynamic> json) {
    return DanmakuMatch(
      episodeId: (json['episodeId'] as num?)?.toInt() ?? 0,
      animeId: (json['animeId'] as num?)?.toInt() ?? 0,
      animeTitle: json['animeTitle'] as String? ?? '',
      episodeTitle: json['episodeTitle'] as String? ?? '',
    );
  }
}

/// 手动搜索到的番剧。
class DanmakuAnime {
  final int animeId;
  final String animeTitle;
  final String typeDescription;
  final int? episodeCount;

  const DanmakuAnime({
    required this.animeId,
    required this.animeTitle,
    required this.typeDescription,
    this.episodeCount,
  });

  factory DanmakuAnime.fromJson(Map<String, dynamic> json) {
    return DanmakuAnime(
      animeId: (json['animeId'] as num?)?.toInt() ?? 0,
      animeTitle: json['animeTitle'] as String? ?? '',
      typeDescription: json['typeDescription'] as String? ?? '',
      episodeCount: (json['episodeCount'] as num?)?.toInt(),
    );
  }
}

/// 番剧下的一集（手动选择用）。
class DanmakuEpisode {
  final int episodeId;
  final String episodeTitle;
  final String episodeNumber;

  const DanmakuEpisode({
    required this.episodeId,
    required this.episodeTitle,
    required this.episodeNumber,
  });

  factory DanmakuEpisode.fromJson(Map<String, dynamic> json) {
    return DanmakuEpisode(
      episodeId: (json['episodeId'] as num?)?.toInt() ?? 0,
      episodeTitle: json['episodeTitle'] as String? ?? '',
      episodeNumber: '${json['episodeNumber'] ?? ''}',
    );
  }
}

/// 弹幕服务：走用户 Plus 服务器的 /api/danmaku/* 代理（服务端再对接
/// dandanplay 兼容的弹幕库），与网页版同一条链路。
class DanmakuService {
  /// 进程内缓存：全屏切换会重建播放器控件，避免重复匹配/拉取。
  static final Map<String, DanmakuMatch?> _matchCache = {};
  static final Map<int, List<DanmakuItem>> _commentsCache = {};

  /// 按文件名自动匹配（fileName 形如「片名 第3集」），未命中返回 null。
  static Future<DanmakuMatch?> autoMatch(String fileName) async {
    if (_matchCache.containsKey(fileName)) return _matchCache[fileName];
    final response = await ApiService.post<Map<String, dynamic>>(
      '/api/danmaku/match',
      body: {'fileName': fileName},
      fromJson: (json) => json as Map<String, dynamic>,
    );
    DanmakuMatch? result;
    if (response.success && response.data != null) {
      final data = response.data!;
      final matches = data['matches'] as List? ?? [];
      if (data['isMatched'] == true && matches.isNotEmpty) {
        result =
            DanmakuMatch.fromJson(matches.first as Map<String, dynamic>);
      }
    }
    _matchCache[fileName] = result;
    return result;
  }

  /// 拉取一集的全部弹幕（按时间排序，过滤空文本）。
  static Future<List<DanmakuItem>> fetchComments(int episodeId) async {
    final cached = _commentsCache[episodeId];
    if (cached != null) return cached;
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/danmaku/comment',
      queryParameters: {'episodeId': '$episodeId'},
      fromJson: (json) => json as Map<String, dynamic>,
    );
    var items = <DanmakuItem>[];
    if (response.success && response.data != null) {
      final comments = response.data!['comments'] as List? ?? [];
      items = comments
          .map((c) => DanmakuItem.fromJson(c as Map<String, dynamic>))
          .where((item) => item.text.trim().isNotEmpty)
          .toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      // 极端热门集弹幕量巨大时等距抽稀，保渲染流畅（上限 9000 条）
      const maxItems = 9000;
      if (items.length > maxItems) {
        final step = items.length / maxItems;
        items = [
          for (var i = 0; i < maxItems; i++) items[(i * step).floor()],
        ];
      }
    }
    _commentsCache[episodeId] = items;
    return items;
  }

  /// 手动搜索番剧。
  static Future<List<DanmakuAnime>> search(String keyword) async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/danmaku/search',
      queryParameters: {'keyword': keyword},
      fromJson: (json) => json as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) return [];
    final animes = response.data!['animes'] as List? ?? [];
    return animes
        .map((a) => DanmakuAnime.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  /// 某番剧的剧集列表。
  static Future<List<DanmakuEpisode>> episodes(int animeId) async {
    final response = await ApiService.get<Map<String, dynamic>>(
      '/api/danmaku/episodes',
      queryParameters: {'animeId': '$animeId'},
      fromJson: (json) => json as Map<String, dynamic>,
    );
    if (!response.success || response.data == null) return [];
    final data = response.data!;
    final bangumi = data['bangumi'] as Map<String, dynamic>?;
    final episodes = (bangumi?['episodes'] ?? data['episodes']) as List? ?? [];
    return episodes
        .map((e) => DanmakuEpisode.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
