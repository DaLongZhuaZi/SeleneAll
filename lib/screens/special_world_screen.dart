import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../main.dart';
import '../models/play_record.dart';
import '../models/video_info.dart';
import '../services/page_cache_service.dart';
import '../services/special_source_service.dart';
import '../services/user_data_service.dart';
import '../widgets/continue_watching_section.dart';
import '../widgets/favorites_grid.dart';
import '../widgets/history_grid.dart';
import '../widgets/video_menu_bottom_sheet.dart';
import 'player_screen.dart';
import 'search_screen.dart';

/// 里世界（MoonTVPlus 特殊源）专属界面。
///
/// 与普通模式完全隔离：
/// - 进入时替换整个导航栈，返回键无法回到普通界面；
/// - 在本页按系统返回键直接退出 App（里世界根页面无处可退）；
/// - 模式状态仅存内存（见 [UserDataService.saveSpecialMode]），
///   关闭 App 后自动回到普通模式；
/// - 四个分页（首页 / 搜索 / 收藏 / 记录）的数据全部走特殊源口径，
///   普通模式的分区与推荐不进入本界面。
class SpecialWorldScreen extends StatefulWidget {
  const SpecialWorldScreen({super.key});

  /// 里世界专属主题：酒红深色，与普通模式一眼可分。
  static ThemeData get worldTheme {
    const primary = Color(0xFFB4233C);
    const background = Color(0xFF150509);
    const surface = Color(0xFF230A12);
    const appBarBg = Color(0xFF1D060E);
    const onSurface = Color(0xFFF5E9EC);

    const colorScheme = ColorScheme.dark(
      primary: primary,
      onPrimary: Colors.white,
      secondary: Color(0xFFE5989B),
      onSecondary: Color(0xFF2A0A12),
      surface: surface,
      onSurface: onSurface,
      error: Color(0xFFFF6B81),
    );

    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: appBarBg,
        foregroundColor: onSurface,
        elevation: 0,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: appBarBg,
        selectedItemColor: Color(0xFFE85D75),
        unselectedItemColor: Color(0xFF9C7A84),
        type: BottomNavigationBarType.fixed,
      ),
      cardColor: surface,
      dividerColor: const Color(0xFF3A1420),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
    );
  }

  @override
  State<SpecialWorldScreen> createState() => _SpecialWorldScreenState();
}

class _SpecialWorldScreenState extends State<SpecialWorldScreen> {
  int _tabIndex = 0;

  /// 从首页源列表点入搜索时预选的来源名（按来源名筛选，口径同搜索页）。
  String? _presetSourceName;

  /// 递增以强制重建搜索页，使预选来源生效。
  int _searchSession = 0;

  Future<void> _exitWorld() async {
    await UserDataService.saveSpecialMode(false);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const AppWrapper()),
      (route) => false,
    );
  }

  void _openPlayer(PlayRecord record) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Theme(
          data: SpecialWorldScreen.worldTheme,
          child: PlayerScreen(
            source: record.source,
            id: record.id,
            title: record.title,
            year: record.year,
          ),
        ),
      ),
    );
  }

  Future<void> _onMenuAction(PlayRecord record, VideoMenuAction action) async {
    final cacheService = PageCacheService();
    switch (action) {
      case VideoMenuAction.play:
        _openPlayer(record);
        break;
      case VideoMenuAction.favorite:
        await cacheService.addFavorite(
          record.source,
          record.id,
          {
            'cover': record.cover,
            'save_time': DateTime.now().millisecondsSinceEpoch,
            'source_name': record.sourceName,
            'title': record.title,
            'total_episodes': record.totalEpisodes,
            'year': record.year,
          },
          context,
        );
        await FavoritesGrid.refreshFavorites();
        break;
      case VideoMenuAction.unfavorite:
        await cacheService.removeFavorite(record.source, record.id, context);
        await FavoritesGrid.refreshFavorites();
        break;
      case VideoMenuAction.deleteRecord:
        await cacheService.deletePlayRecord(record.source, record.id, context);
        await HistoryGrid.refreshHistory();
        await ContinueWatchingSection.refreshPlayRecords();
        break;
      case VideoMenuAction.doubanDetail:
      case VideoMenuAction.bangumiDetail:
        // 详情跳转由菜单组件内部处理，这里不额外动作
        break;
    }
  }

  /// FavoritesGrid 的菜单回调传的是 VideoInfo，先转成 PlayRecord 再统一处理。
  void _onMenuActionFromVideoInfo(VideoInfo info, VideoMenuAction action) {
    final record = PlayRecord(
      id: info.id,
      source: info.source,
      title: info.title,
      sourceName: info.sourceName,
      year: info.year,
      cover: info.cover,
      index: info.index,
      totalEpisodes: info.totalEpisodes,
      playTime: info.playTime,
      totalTime: info.totalTime,
      saveTime: info.saveTime,
      searchTitle: info.searchTitle,
    );
    _onMenuAction(record, action);
  }

  void _goSearchWithSource(String sourceName) {
    setState(() {
      _presetSourceName = sourceName;
      _searchSession++;
      _tabIndex = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          // 里世界根页面按返回键：直接退出 App，不回普通模式
          SystemNavigator.pop();
        }
      },
      child: Theme(
        data: SpecialWorldScreen.worldTheme,
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.moon, size: 20, color: Color(0xFFE85D75)),
                SizedBox(width: 8),
                Text('里世界'),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: _exitWorld,
                icon: const Icon(LucideIcons.logOut, size: 18),
                label: const Text('退出里世界'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFE5989B),
                ),
              ),
            ],
          ),
          body: IndexedStack(
            index: _tabIndex,
            children: [
              _buildHomeTab(),
              SearchScreen(
                key: ValueKey('world-search-$_searchSession'),
                initialSourceName: _presetSourceName,
              ),
              FavoritesGrid(
                onVideoTap: _openPlayer,
                onGlobalMenuAction: _onMenuActionFromVideoInfo,
              ),
              HistoryGrid(
                onVideoTap: _openPlayer,
                onGlobalMenuAction: _onMenuAction,
              ),
            ],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _tabIndex,
            onTap: (index) => setState(() => _tabIndex = index),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(LucideIcons.house),
                label: '首页',
              ),
              BottomNavigationBarItem(
                icon: Icon(LucideIcons.search),
                label: '搜索',
              ),
              BottomNavigationBarItem(
                icon: Icon(LucideIcons.heart),
                label: '收藏',
              ),
              BottomNavigationBarItem(
                icon: Icon(LucideIcons.history),
                label: '记录',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTab() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 世界横幅
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: const LinearGradient(
                colors: [Color(0xFF6E0E2A), Color(0xFF3A0A18)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '里世界',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '特殊源专属空间 · 与普通模式完全隔离 · 关闭 App 自动退出',
                  style: TextStyle(fontSize: 12, color: Color(0xFFE8C4CC)),
                ),
              ],
            ),
          ),
          // 搜索入口
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => setState(() => _tabIndex = 1),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF5A1E30)),
                  color: const Color(0xFF230A12),
                ),
                child: const Row(
                  children: [
                    Icon(LucideIcons.search,
                        size: 18, color: Color(0xFF9C7A84)),
                    SizedBox(width: 10),
                    Text(
                      '搜索里世界的内容…',
                      style: TextStyle(color: Color(0xFF9C7A84), fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 继续观看（数据层已按特殊源过滤）
          ContinueWatchingSection(
            onVideoTap: _openPlayer,
            onGlobalMenuAction: _onMenuAction,
            onViewAll: () => setState(() => _tabIndex = 3),
          ),
          // 特殊源浏览
          _buildSourceBrowser(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildSourceBrowser() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: SpecialSourceService.getSpecialSources(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final sources = snapshot.data ?? const [];
        if (sources.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '暂无特殊源（服务器未返回特殊源列表）',
              style: TextStyle(color: Color(0xFF9C7A84)),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '特殊源 · ${sources.length} 个',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFF5E9EC),
                ),
              ),
            ),
            for (final source in sources)
              ListTile(
                leading: const Icon(LucideIcons.server,
                    size: 20, color: Color(0xFFE5989B)),
                title: Text(
                  (source['name'] as String?) ??
                      (source['key'] as String?) ??
                      '未知来源',
                  style: const TextStyle(color: Color(0xFFF5E9EC)),
                ),
                trailing: const Icon(LucideIcons.chevronRight,
                    size: 18, color: Color(0xFF9C7A84)),
                onTap: () {
                  final name = (source['name'] as String?) ??
                      (source['key'] as String?);
                  if (name != null) {
                    _goSearchWithSource(name);
                  }
                },
              ),
          ],
        );
      },
    );
  }
}
