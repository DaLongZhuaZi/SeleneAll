import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../models/search_result.dart';
import '../models/video_info.dart';
import '../services/source_browse_service.dart';
import '../services/theme_service.dart';
import '../widgets/cover_diagnostic.dart';
import '../widgets/search_results_grid.dart';
import '../widgets/video_menu_bottom_sheet.dart';

/// 按源浏览页：展示某个源的分类与分类下的视频列表（分页加载）。
///
/// 数据走 MoonTVPlus 的 /api/source-search/categories 与
/// /api/source-search/videos；特殊模式下 ApiService 自动附加 special=1。
class SourceBrowseScreen extends StatefulWidget {
  final String sourceKey;
  final String sourceName;
  final Function(VideoInfo)? onVideoTap;
  final Function(VideoInfo, VideoMenuAction)? onGlobalMenuAction;

  /// 跳转到搜索页并预选该源（源无分类可浏览时兜底，也供顶栏搜索按钮使用）。
  final VoidCallback? onSearchSource;

  const SourceBrowseScreen({
    super.key,
    required this.sourceKey,
    required this.sourceName,
    this.onVideoTap,
    this.onGlobalMenuAction,
    this.onSearchSource,
  });

  @override
  State<SourceBrowseScreen> createState() => _SourceBrowseScreenState();
}

class _SourceBrowseScreenState extends State<SourceBrowseScreen> {
  List<SourceCategory> _categories = const [];
  SourceCategory? _selectedCategory;
  bool _loadingCategories = true;
  String? _categoriesError;

  List<SearchResult> _results = const [];
  int _page = 0;
  int _pageCount = 0;
  bool _loadingVideos = false;
  bool _loadingMore = false;
  String? _videosError;

  /// 请求代次：切换分类后旧请求返回直接丢弃，避免串数据。
  int _requestToken = 0;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    setState(() {
      _loadingCategories = true;
      _categoriesError = null;
    });
    try {
      final categories =
          await SourceBrowseService.getCategories(widget.sourceKey);
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _loadingCategories = false;
      });
      if (categories.isNotEmpty) {
        final firstTopLevel = categories.firstWhere(
          (c) => c.pid == '0',
          orElse: () => categories.first,
        );
        _selectCategory(firstTopLevel);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCategories = false;
        _categoriesError = e.toString();
      });
    }
  }

  void _selectCategory(SourceCategory category) {
    if (_selectedCategory?.id == category.id && _results.isNotEmpty) return;
    setState(() {
      _selectedCategory = category;
      _results = const [];
      _page = 0;
      _pageCount = 0;
      _videosError = null;
    });
    _loadVideos(1, append: false);
  }

  Future<void> _loadVideos(int page, {required bool append}) async {
    final category = _selectedCategory;
    if (category == null) return;
    final token = ++_requestToken;
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _loadingVideos = true;
        _videosError = null;
      }
    });
    try {
      final result = await SourceBrowseService.getVideos(
        widget.sourceKey,
        category.id,
        page,
      );
      if (!mounted || token != _requestToken) return;
      setState(() {
        _results =
            append ? [..._results, ...result.results] : result.results;
        _page = result.page;
        _pageCount = result.pageCount;
        _loadingVideos = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || token != _requestToken) return;
      setState(() {
        _loadingVideos = false;
        _loadingMore = false;
        if (!append) _videosError = e.toString();
      });
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    final metrics = notification.metrics;
    if (metrics.pixels >= metrics.maxScrollExtent - 400 &&
        !_loadingVideos &&
        !_loadingMore &&
        _page >= 1 &&
        _page < _pageCount) {
      _loadVideos(_page + 1, append: true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sourceName),
        actions: [
          if (_results.isNotEmpty)
            IconButton(
              icon: const Icon(LucideIcons.bug, size: 20),
              tooltip: '封面诊断',
              onPressed: () =>
                  CoverDiagnostic.show(context, _results.first.poster),
            ),
          if (widget.onSearchSource != null)
            IconButton(
              icon: const Icon(LucideIcons.search, size: 20),
              tooltip: '搜该源',
              onPressed: widget.onSearchSource,
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loadingCategories) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_categoriesError != null) {
      return _buildErrorView(_categoriesError!, _loadCategories);
    }
    if (_categories.isEmpty) {
      // 源没有提供分类浏览（如少数非 CMS 源）：回退到按源搜索
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.folderOpen, size: 56),
              const SizedBox(height: 16),
              const Text('该源未提供分类浏览'),
              const SizedBox(height: 16),
              if (widget.onSearchSource != null)
                FilledButton.icon(
                  onPressed: widget.onSearchSource,
                  icon: const Icon(LucideIcons.search, size: 18),
                  label: const Text('去搜该源的内容'),
                ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        _buildCategoryBar(),
        if (_loadingMore) const LinearProgressIndicator(minHeight: 2),
        Expanded(child: _buildResults()),
      ],
    );
  }

  Widget _buildCategoryBar() {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = _categories[index];
          final selected = category.id == _selectedCategory?.id;
          return ChoiceChip(
            label: Text(category.name),
            selected: selected,
            onSelected: (_) => _selectCategory(category),
          );
        },
      ),
    );
  }

  Widget _buildResults() {
    if (_loadingVideos) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_videosError != null) {
      return _buildErrorView(
        _videosError!,
        () => _loadVideos(1, append: false),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('该分类暂无内容'));
    }
    final themeService = context.read<ThemeService>();
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: SearchResultsGrid(
        results: _results,
        themeService: themeService,
        onVideoTap: widget.onVideoTap,
        onGlobalMenuAction: widget.onGlobalMenuAction,
        hasReceivedStart: true,
      ),
    );
  }

  Widget _buildErrorView(String message, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.cloudOff, size: 48),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
