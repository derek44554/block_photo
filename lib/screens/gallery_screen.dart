import 'dart:io' show Platform;

import 'package:block_flutter/block_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/photo_collection.dart';
import '../providers/connection_provider.dart';
import '../providers/photo_provider.dart';
import '../services/block_service.dart';
import '../services/image_service.dart';
import '../widgets/photo_grid_item.dart';
import 'photo_detail_screen.dart';
import 'settings_screen.dart';
import 'setup_screen.dart';
import 'upload_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final List<PhotoItem> _photos = [];
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  int? _selectedCollectionIndex;
  final _scrollCtrl = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // 全量 BID 列表（同步后持久化）
  List<String> _allBids = [];
  bool _syncing = false;
  int _syncFetched = 0;
  int _syncTotal = 0;
  ImageService? _imageService;

  // "全部"视图已完成初次加载，切回时不重复请求
  bool _allViewLoaded = false;
  List<PhotoItem> _allViewPhotos = [];
  List<String> _allViewBids = [];
  int _allViewPage = 1;
  bool _allViewHasMore = true;

  // 拖拽追踪
  double? _dragStartX;

  // 当前选中的 link_tag 过滤标签
  String? _selectedTag;

  // macOS 右侧区域内部详情页状态（保持左侧导航固定）
  int? _macDetailInitialIndex;
  final GlobalKey<NavigatorState> _macPaneNavigatorKey =
      GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMore(reset: true);
      _refreshCollections();
    });
  }

  Future<void> _refreshCollections() async {
    final connProvider = context.read<ConnectionProvider>();
    if (!connProvider.hasActiveConnection) return;
    final service = BlockService(connProvider);
    await context.read<PhotoProvider>().refreshCollections(
      service.fetchCollectionBlock,
    );
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 400) {
      _loadMore();
    }
    // 预加载当前可见区域后方的图片
    if (_imageService != null && _photos.isNotEmpty) {
      final itemHeight = _scrollCtrl.position.viewportDimension / 3;
      final currentRow = (_scrollCtrl.position.pixels / itemHeight).floor();
      final visibleRows = (_scrollCtrl.position.viewportDimension / itemHeight)
          .ceil();
      final preloadStart = (currentRow + visibleRows) * 3;
      if (preloadStart < _photos.length) {
        _preloadImages(_imageService!, preloadStart, 12);
      }
    }
  }

  List<String> _getBidsToQuery() {
    final provider = context.read<PhotoProvider>();
    if (_selectedCollectionIndex != null &&
        _selectedCollectionIndex! < provider.collections.length) {
      return [provider.collections[_selectedCollectionIndex!].bid];
    }
    return provider.albumCollections.map((c) => c.bid).toList();
  }

  Future<void> _loadMore({bool reset = false}) async {
    if (_loading) return;
    if (!reset && !_hasMore) return;

    // tag 选中时走独立的直接请求路径（不缓存）
    if (_selectedTag != null && _selectedCollectionIndex != null) {
      await _loadByTag(reset: reset);
      return;
    }

    final bids = _getBidsToQuery();
    if (bids.isEmpty) {
      setState(() {
        _photos.clear();
        _allBids = [];
        _hasMore = false;
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final service = BlockService(context.read<ConnectionProvider>());

      if (reset) {
        _page = 1;
        _allBids = await _loadCachedBids(bids, tag: _selectedTag);

        if (_allBids.isNotEmpty) {
          final blocks = await service.getLocalBlocks(
            bids: _allBids,
            page: 1,
            limit: 40,
          );
          final photos = blocks.map(PhotoItem.fromBlock).toList();
          if (mounted) {
            setState(() {
              _photos
                ..clear()
                ..addAll(photos);
              _page = 2;
              _hasMore = photos.length == 40;
              _loading = false;
            });
          }
          // 预加载第一页图片到内存
          if (_imageService != null) {
            _preloadImages(_imageService!, 0, photos.length);
          }
        } else {
          // 没有本地缓存，保持 loading 状态直到同步完成
          if (mounted) setState(() => _loading = true);
        }

        // 无论有没有本地缓存都后台同步
        _syncInBackground(bids, tag: _selectedTag);
        return;
      }

      // 翻页：直接从本地缓存读
      final blocks = await service.getLocalBlocks(
        bids: _allBids,
        page: _page,
        limit: 40,
      );
      final photos = blocks.map(PhotoItem.fromBlock).toList();
      if (mounted) {
        setState(() {
          _photos.addAll(photos);
          _page++;
          _hasMore = photos.length == 40;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted && !_syncing) setState(() => _loading = false);
    }
  }

  /// tag 选中时直接请求，不走本地缓存
  Future<void> _loadByTag({bool reset = false}) async {
    if (_loading) return;
    final provider = context.read<PhotoProvider>();
    final collectionBid = provider.collections[_selectedCollectionIndex!].bid;
    final tag = _selectedTag!;

    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _photos.clear();
        _page = 1;
      }
    });
    try {
      final service = BlockService(context.read<ConnectionProvider>());
      final response = await service.getLinksByMainWithTag(
        collectionBid: collectionBid,
        tag: tag,
        page: _page,
        limit: 40,
      );
      final photos = response.map(PhotoItem.fromBlock).toList();
      if (mounted) {
        setState(() {
          if (reset) {
            _photos
              ..clear()
              ..addAll(photos);
            _page = 2;
          } else {
            _photos.addAll(photos);
            _page++;
          }
          _hasMore = photos.length == 40;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 从本地 SharedPreferences 读取上次缓存的 BID 列表
  Future<List<String>> _loadCachedBids(
    List<String> collectionBids, {
    String? tag,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'gallery_bids_${collectionBids.join(',')}${tag != null ? '_$tag' : ''}';
    return prefs.getStringList(key) ?? [];
  }

  Future<void> _saveCachedBids(
    List<String> collectionBids,
    List<String> bids, {
    String? tag,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key =
        'gallery_bids_${collectionBids.join(',')}${tag != null ? '_$tag' : ''}';
    await prefs.setStringList(key, bids);
  }

  Future<void> _syncInBackground(
    List<String> collectionBids, {
    String? tag,
  }) async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _syncFetched = 0;
      _syncTotal = 0;
    });
    try {
      final service = BlockService(context.read<ConnectionProvider>());
      final newBids = await service.syncCollectionBids(
        collectionBids: collectionBids,
        tag: tag,
        onProgress: (fetched, total) {
          if (mounted) {
            setState(() {
              _syncFetched = fetched;
              _syncTotal = total;
            });
          }
        },
      );
      await _saveCachedBids(collectionBids, newBids, tag: tag);
      if (mounted) {
        // 同步完成后刷新展示
        _allBids = newBids;
        _page = 1;
        final blocks = await service.getLocalBlocks(
          bids: _allBids,
          page: 1,
          limit: 40,
        );
        final photos = blocks.map(PhotoItem.fromBlock).toList();
        if (mounted) {
          setState(() {
            _photos
              ..clear()
              ..addAll(photos);
            _page = 2;
            _hasMore = photos.length == 40;
          });
        }
        if (_imageService != null) {
          _preloadImages(_imageService!, 0, photos.length);
        }
        // 如果是"全部"视图，保存快照
        if (_selectedCollectionIndex == null && _selectedTag == null) {
          _allViewLoaded = true;
          _allViewPhotos = List.from(_photos);
          _allViewBids = List.from(_allBids);
          _allViewPage = _page;
          _allViewHasMore = _hasMore;
        }
      }
    } catch (_) {
      // 后台同步失败不影响已展示内容
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _preloadImages(
    ImageService imageService,
    int fromIndex,
    int count,
  ) async {
    final end = (fromIndex + count).clamp(0, _photos.length);
    for (var i = fromIndex; i < end; i++) {
      final photo = _photos[i];
      if (ImageCacheHelper.getMemoryImage(
            photo.cid,
            variant: ImageVariant.squareThumb,
          ) !=
          null) {
        continue;
      }
      final file = await ImageCacheHelper.getCachedImage(
        photo.cid,
        variant: ImageVariant.squareThumb,
      );
      if (file != null) {
        final bytes = await file.readAsBytes();
        ImageCacheHelper.cacheMemoryImage(
          photo.cid,
          bytes,
          variant: ImageVariant.squareThumb,
        );
      }
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _page = 1;
      _hasMore = true;
      _error = null;
    });
    await _loadMore(reset: true);
  }

  void _selectCollection(int? index) {
    // 切回"全部"且已有快照，直接恢复不重新请求
    if (index == null && _allViewLoaded) {
      setState(() {
        _selectedCollectionIndex = null;
        _selectedTag = null;
        _macDetailInitialIndex = null;
        _photos
          ..clear()
          ..addAll(_allViewPhotos);
        _allBids = List.from(_allViewBids);
        _page = _allViewPage;
        _hasMore = _allViewHasMore;
        _error = null;
      });
      _scaffoldKey.currentState?.closeEndDrawer();
      return;
    }
    setState(() {
      _selectedCollectionIndex = index;
      _selectedTag = null;
      _macDetailInitialIndex = null;
      _page = 1;
      _hasMore = true;
      _error = null;
      _photos.clear();
      _allBids = [];
    });
    _scaffoldKey.currentState?.closeEndDrawer();
    _loadMore(reset: true);
  }

  void _selectTag(String? tag) {
    if (tag == _selectedTag) {
      return;
    }
    setState(() {
      _selectedTag = tag;
      _macDetailInitialIndex = null;
      _page = 1;
      _hasMore = true;
      _error = null;
      _photos.clear();
      _allBids = [];
    });
    _scaffoldKey.currentState?.closeEndDrawer();
    _loadMore(reset: true);
  }

  String get _currentTitle {
    final provider = context.read<PhotoProvider>();
    if (_selectedCollectionIndex != null &&
        _selectedCollectionIndex! < provider.collections.length) {
      final col = provider.collections[_selectedCollectionIndex!];
      return col.title ?? col.bid.substring(0, 8);
    }
    return 'BlockPhoto';
  }

  Future<void> _openUpload() async {
    final isMacDesktop = !kIsWeb && Platform.isMacOS;
    if (isMacDesktop) {
      final paneNavigator = _macPaneNavigatorKey.currentState;
      if (paneNavigator != null) {
        final result = await paneNavigator.push<bool>(
          MaterialPageRoute(builder: (_) => const UploadScreen()),
        );
        if (result == true && mounted) {
          await _refresh();
        }
      }
      return;
    }

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const UploadScreen()),
    );
    if (result == true) {
      await _refresh();
    }
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final connProvider = context.watch<ConnectionProvider>();
    final photoProvider = context.watch<PhotoProvider>();
    final imageService = ImageService(connProvider);
    _imageService = imageService;
    final hasCollections = photoProvider.collections.isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMacDesktop = !kIsWeb && Platform.isMacOS;
        if (isMacDesktop) {
          return _buildMacScaffold(
            connProvider: connProvider,
            photoProvider: photoProvider,
            imageService: imageService,
            hasCollections: hasCollections,
          );
        }
        return _buildMobileScaffold(
          connProvider: connProvider,
          photoProvider: photoProvider,
          imageService: imageService,
          hasCollections: hasCollections,
        );
      },
    );
  }

  Widget _buildMobileScaffold({
    required ConnectionProvider connProvider,
    required PhotoProvider photoProvider,
    required ImageService imageService,
    required bool hasCollections,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      key: _scaffoldKey,
      // 禁用默认的左边缘手势，我们自己处理右边缘
      drawerEnableOpenDragGesture: false,
      endDrawerEnableOpenDragGesture: false,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.photo_library_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                connProvider.hasActiveConnection ? _currentTitle : 'BlockPhoto',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          if (_syncing)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: _syncTotal > 0 ? _syncFetched / _syncTotal : null,
                    color: cs.primary,
                  ),
                ),
              ),
            ),
          if (connProvider.hasActiveConnection && hasCollections) ...[
            IconButton(
              icon: const Icon(Icons.add_photo_alternate_rounded),
              tooltip: '上传图片',
              onPressed: _openUpload,
            ),
            IconButton(
              icon: Badge(
                isLabelVisible: _selectedCollectionIndex != null,
                child: const Icon(Icons.collections_bookmark_rounded),
              ),
              tooltip: '集合',
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            ),
          ],
          const SizedBox(width: 4),
        ],
      ),
      endDrawer: hasCollections
          ? _CollectionDrawer(
              collections: photoProvider.collections,
              selectedIndex: _selectedCollectionIndex,
              onSelect: _selectCollection,
              onAdd: () {
                _scaffoldKey.currentState?.closeEndDrawer();
                _showAddCollectionDialog(context);
              },
              onSettings: () async {
                _scaffoldKey.currentState?.closeEndDrawer();
                await _openSettings();
              },
              onDelete: (col) {
                context.read<PhotoProvider>().removeCollection(col.bid);
                if (_selectedCollectionIndex != null) {
                  setState(() => _selectedCollectionIndex = null);
                  _loadMore(reset: true);
                }
              },
              onToggleDefault: (col, isDefault) {
                context.read<PhotoProvider>().toggleDefault(col.bid, isDefault);
                // 如果当前在"全部"视图，刷新以反映新的默认集合
                if (_selectedCollectionIndex == null) _loadMore(reset: true);
              },
              selectedTag: _selectedTag,
              onSelectTag: _selectTag,
            )
          : null,
      body: !connProvider.hasActiveConnection
          ? _buildNoConnection()
          : _buildBodyWithEdgeGesture(imageService, hasCollections),
    );
  }

  Widget _buildMacScaffold({
    required ConnectionProvider connProvider,
    required PhotoProvider photoProvider,
    required ImageService imageService,
    required bool hasCollections,
  }) {
    return Scaffold(
      backgroundColor: const Color(0xFF070D1C),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B1124), Color(0xFF111B33), Color(0xFF080D1C)],
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 1200;
              final sideWidth = isCompact ? 288.0 : 320.0;
              final gap = isCompact ? 8.0 : 10.0;
              return Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: sideWidth,
                      child: _CollectionDrawer(
                        embedded: true,
                        brandTitle: 'BlockPhoto',
                        collections: photoProvider.collections,
                        selectedIndex: _selectedCollectionIndex,
                        onSelect: _selectCollection,
                        onAdd: () => _showAddCollectionDialog(context),
                        onUpload:
                            connProvider.hasActiveConnection && hasCollections
                            ? _openUpload
                            : null,
                        onSettings: _openSettings,
                        onDelete: (col) {
                          context.read<PhotoProvider>().removeCollection(
                            col.bid,
                          );
                          if (_selectedCollectionIndex != null) {
                            setState(() => _selectedCollectionIndex = null);
                            _loadMore(reset: true);
                          }
                        },
                        onToggleDefault: (col, isDefault) {
                          context.read<PhotoProvider>().toggleDefault(
                            col.bid,
                            isDefault,
                          );
                          if (_selectedCollectionIndex == null) {
                            _loadMore(reset: true);
                          }
                        },
                        selectedTag: _selectedTag,
                        onSelectTag: _selectTag,
                      ),
                    ),
                    SizedBox(width: gap),
                    Expanded(
                      child: Navigator(
                        key: _macPaneNavigatorKey,
                        pages: [
                          MaterialPage<void>(
                            key: const ValueKey<String>('mac-pane-root'),
                            child: !connProvider.hasActiveConnection
                                ? _buildNoConnection(isDesktop: true)
                                : _buildGrid(imageService, openInMacPane: true),
                          ),
                          if (_macDetailInitialIndex != null)
                            MaterialPage<int>(
                              key: ValueKey<String>(
                                'mac-pane-detail-$_macDetailInitialIndex-${_photos.length}',
                              ),
                              child: PhotoDetailScreen(
                                photos: _photos,
                                initialIndex: _macDetailInitialIndex!,
                                imageService: imageService,
                                connectionProvider: context
                                    .read<ConnectionProvider>(),
                                collections: context
                                    .read<PhotoProvider>()
                                    .collections,
                              ),
                            ),
                        ],
                        onDidRemovePage: (page) {
                          final isDetailPage =
                              page.key is ValueKey<String> &&
                              (page.key as ValueKey<String>).value.startsWith(
                                'mac-pane-detail-',
                              );
                          if (!isDetailPage || _macDetailInitialIndex == null) {
                            return;
                          }
                          setState(() {
                            _macDetailInitialIndex = null;
                          });
                        },
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 在 body 上叠加全屏手势检测层
  Widget _buildBodyWithEdgeGesture(
    ImageService imageService,
    bool hasCollections,
  ) {
    return GestureDetector(
      onHorizontalDragStart: !hasCollections
          ? null
          : (details) {
              _dragStartX = details.globalPosition.dx;
            },
      onHorizontalDragUpdate: !hasCollections
          ? null
          : (details) {
              if (_dragStartX == null) return;
              final delta = _dragStartX! - details.globalPosition.dx;
              // 向左滑超过 20px 触发打开
              if (delta > 20) {
                _scaffoldKey.currentState?.openEndDrawer();
                _dragStartX = null;
              }
            },
      onHorizontalDragEnd: (_) => _dragStartX = null,
      behavior: HitTestBehavior.translucent,
      child: _buildGrid(imageService),
    );
  }

  Widget _buildNoConnection({bool isDesktop = false}) {
    final cs = Theme.of(context).colorScheme;
    final iconBg = isDesktop ? cs.surface : cs.surfaceContainerHigh;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '尚未配置节点',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '添加一个 Block 节点来开始浏览你的加密相册',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () =>
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SetupScreen()),
                  ).then((_) {
                    if (!mounted) {
                      return;
                    }
                    if (context
                        .read<ConnectionProvider>()
                        .hasActiveConnection) {
                      _loadMore();
                    }
                  }),
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加节点'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(ImageService imageService, {bool openInMacPane = false}) {
    if (_photos.isEmpty && (_loading || _syncing)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_photos.isEmpty && _error != null) return _buildErrorState();
    if (_photos.isEmpty) return _buildEmptyState();

    final isMac = !kIsWeb && Platform.isMacOS;
    return LayoutBuilder(
      builder: (context, constraints) {
        final minItemWidth = isMac ? 132.0 : 110.0;
        final crossSpacing = isMac ? 4.0 : 2.0;
        final mainSpacing = isMac ? 4.0 : 2.0;
        final crossAxisCount =
            ((constraints.maxWidth + crossSpacing) /
                    (minItemWidth + crossSpacing))
                .floor()
                .clamp(isMac ? 4 : 3, isMac ? 9 : 8);

        return GridView.builder(
          key: ValueKey('$_selectedCollectionIndex$_selectedTag'),
          controller: _scrollCtrl,
          padding: isMac
              ? const EdgeInsets.symmetric(horizontal: 4, vertical: 6)
              : const EdgeInsets.all(2),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: crossSpacing,
            mainAxisSpacing: mainSpacing,
          ),
          itemCount: _photos.length + (_loading ? crossAxisCount : 0),
          itemBuilder: (context, index) {
            if (index >= _photos.length) return _buildLoadingPlaceholder();
            final photo = _photos[index];
            final horizontalPadding = isMac ? 8.0 : 4.0;
            final itemWidth =
                (constraints.maxWidth -
                    crossSpacing * (crossAxisCount - 1) -
                    horizontalPadding) /
                crossAxisCount;
            return PhotoGridItem(
              photo: photo,
              imageService: imageService,
              onTap: () async {
                if (openInMacPane) {
                  setState(() {
                    _macDetailInitialIndex = index;
                  });
                  return;
                }
                final result = await Navigator.push<int>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PhotoDetailScreen(
                      photos: _photos,
                      initialIndex: index,
                      imageService: imageService,
                      connectionProvider: context.read<ConnectionProvider>(),
                      collections: context.read<PhotoProvider>().collections,
                    ),
                  ),
                );
                if (result != null && _scrollCtrl.hasClients) {
                  final row = result ~/ crossAxisCount;
                  final itemTop = row * (itemWidth + mainSpacing) + 2;
                  final itemBottom = itemTop + itemWidth;
                  final viewTop = _scrollCtrl.offset;
                  final viewBottom =
                      viewTop + _scrollCtrl.position.viewportDimension;
                  // 已在可视范围内就不跳
                  if (itemTop < viewTop || itemBottom > viewBottom) {
                    _scrollCtrl.jumpTo(
                      itemTop.clamp(0.0, _scrollCtrl.position.maxScrollExtent),
                    );
                  }
                }
              },
            );
          },
        );
      },
    );
  }

  Widget _buildLoadingPlaceholder() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: cs.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: cs.errorContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.wifi_off_rounded,
                size: 36,
                color: cs.onErrorContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '加载失败',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.photo_library_outlined,
                size: 40,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '暂无图片',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '点击右下角按钮添加集合 BID\n即可浏览加密相册中的图片',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddCollectionDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _AddCollectionDialog(
        onSubmit: (bid) async {
          final connProvider = this.context.read<ConnectionProvider>();
          final photoProvider = this.context.read<PhotoProvider>();
          final service = BlockService(connProvider);
          final block = await service.getBlock(bid);
          final collection = PhotoCollection(
            bid: block.bid ?? bid,
            block: block.data,
            isAlbum: true,
          );
          await photoProvider.addCollection(collection);
          if (!mounted) {
            return;
          }
          await _refresh();
        },
      ),
    );
  }
}

// ── 右侧集合抽屉 ──────────────────────────────────────────────

class _CollectionDrawer extends StatefulWidget {
  const _CollectionDrawer({
    required this.collections,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAdd,
    this.onUpload,
    required this.onSettings,
    required this.onDelete,
    required this.onToggleDefault,
    this.embedded = false,
    this.brandTitle = 'BlockPhoto',
    this.selectedTag,
    this.onSelectTag,
  });

  final List<PhotoCollection> collections;
  final int? selectedIndex;
  final void Function(int? index) onSelect;
  final VoidCallback onAdd;
  final VoidCallback? onUpload;
  final VoidCallback onSettings;
  final void Function(PhotoCollection col) onDelete;
  final void Function(PhotoCollection col, bool isDefault) onToggleDefault;
  final bool embedded;
  final String brandTitle;
  final String? selectedTag;
  final void Function(String? tag)? onSelectTag;

  @override
  State<_CollectionDrawer> createState() => _CollectionDrawerState();
}

class _CollectionDrawerState extends State<_CollectionDrawer> {
  // 记录每个集合是否展开 tags，key 为集合 bid
  final Map<String, bool> _expanded = {};

  bool _isExpanded(PhotoCollection col) {
    // 默认：选中的集合自动展开
    return _expanded[col.bid] ??
        (widget.selectedIndex != null &&
            widget.collections.indexOf(col) == widget.selectedIndex);
  }

  void _toggleExpanded(PhotoCollection col) {
    setState(() {
      _expanded[col.bid] = !_isExpanded(col);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1F2D50), Color(0xFF1A2742)],
                ),
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      gradient: const LinearGradient(
                        colors: [Color(0xFF6E8CFF), Color(0xFF56C7D8)],
                      ),
                    ),
                    child: const Icon(
                      Icons.photo_library_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.brandTitle,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Mac 工作区',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, widget.embedded ? 8 : 16, 12, 8),
          child: Row(
            children: [
              Icon(
                Icons.collections_bookmark_rounded,
                color: cs.primary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Text(
                '我的集合',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_rounded),
                tooltip: '添加集合',
                onPressed: widget.onAdd,
              ),
              if (widget.onUpload != null)
                IconButton(
                  icon: const Icon(Icons.add_photo_alternate_rounded),
                  tooltip: '上传图片',
                  onPressed: widget.onUpload,
                ),
            ],
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 4),
        _CollectionTile(
          icon: Icons.photo_library_rounded,
          label: '全部',
          selected: widget.selectedIndex == null,
          onTap: () => widget.onSelect(null),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            '集合列表',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              letterSpacing: 0.8,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: widget.collections.length,
            itemBuilder: (context, i) {
              final col = widget.collections[i];
              final isSelected = widget.selectedIndex == i;
              final tags = col.linkTags;
              final hasTags = tags.isNotEmpty;
              final expanded = _isExpanded(col);

              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CollectionTile(
                    icon: Icons.folder_rounded,
                    label: col.title ?? col.bid.substring(0, 10),
                    subtitle: col.bid.length > 14
                        ? '${col.bid.substring(0, 6)}…${col.bid.substring(col.bid.length - 4)}'
                        : col.bid,
                    selected: isSelected,
                    onTap: () => widget.onSelect(i),
                    onLongPress: () => _showDeleteSheet(context, col),
                    isDefault: col.isDefault,
                    trailingWidget: hasTags
                        ? GestureDetector(
                            onTap: () => _toggleExpanded(col),
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                expanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                size: 18,
                                color: isSelected
                                    ? cs.onPrimaryContainer
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          )
                        : null,
                  ),
                  if (hasTags && expanded)
                    ...tags.map(
                      (tag) => _TagTile(
                        tag: tag,
                        selected: widget.selectedTag == tag,
                        onTap: () => widget.onSelectTag?.call(tag),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
        InkWell(
          onTap: widget.onSettings,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              children: [
                Icon(
                  Icons.settings_rounded,
                  size: 20,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text('设置', style: TextStyle(fontSize: 14, color: cs.onSurface)),
                const Spacer(),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ],
    );

    if (widget.embedded) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF192542), Color(0xFF121B31)],
          ),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.68)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: content,
        ),
      );
    }

    return Drawer(width: 280, child: SafeArea(child: content));
  }

  void _showDeleteSheet(BuildContext context, PhotoCollection col) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 4,
                ),
                child: Text(
                  col.title ?? col.bid,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: Icon(
                  col.isDefault
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  color: col.isDefault ? Colors.amber : cs.onSurfaceVariant,
                ),
                title: Text(col.isDefault ? '取消默认显示' : '加入默认显示'),
                onTap: () {
                  Navigator.pop(context);
                  widget.onToggleDefault(col, !col.isDefault);
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: Icon(Icons.copy_rounded, color: cs.onSurfaceVariant),
                title: const Text('复制 BID'),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: col.bid));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制 BID'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: Icon(Icons.delete_outline_rounded, color: cs.error),
                title: Text('删除集合', style: TextStyle(color: cs.error)),
                onTap: () {
                  Navigator.pop(context);
                  widget.onDelete(col);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TagTile extends StatelessWidget {
  const _TagTile({
    required this.tag,
    required this.selected,
    required this.onTap,
  });
  final String tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 28, right: 8, top: 1, bottom: 1),
      child: Material(
        color: selected ? cs.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.label_outline_rounded,
                  size: 15,
                  color: selected
                      ? cs.onSecondaryContainer
                      : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tag,
                    style: TextStyle(
                      fontSize: 13,
                      color: selected ? cs.onSecondaryContainer : cs.onSurface,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected)
                  Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: cs.onSecondaryContainer,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.onLongPress,
    this.isDefault = false,
    this.trailingWidget,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isDefault;
  final Widget? trailingWidget;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final iconColor = selected
        ? cs.onPrimaryContainer
        : isDefault
        ? cs.tertiary
        : cs.onSurfaceVariant;
    final labelColor = selected ? cs.onPrimaryContainer : cs.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: selected ? cs.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: labelColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 11,
                            color: selected
                                ? cs.onPrimaryContainer.withValues(alpha: 0.7)
                                : cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailingWidget != null) trailingWidget!,
                if (selected && trailingWidget == null)
                  Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: cs.onPrimaryContainer,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 添加集合对话框 ─────────────────────────────────────────────

class _AddCollectionDialog extends StatefulWidget {
  const _AddCollectionDialog({required this.onSubmit});
  final Future<void> Function(String bid) onSubmit;

  @override
  State<_AddCollectionDialog> createState() => _AddCollectionDialogState();
}

class _AddCollectionDialogState extends State<_AddCollectionDialog> {
  final _ctrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(Icons.add_circle_outline_rounded, color: cs.primary, size: 22),
          const SizedBox(width: 8),
          const Text('添加集合'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '输入集合的 BID 来加载其中的图片',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _ctrl,
              decoration: const InputDecoration(
                labelText: '集合 BID',
                hintText: '粘贴 BID...',
                prefixIcon: Icon(Icons.tag_rounded),
              ),
              autofocus: true,
              validator: (v) =>
                  v == null || v.trim().isEmpty ? '请输入 BID' : null,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 16,
                        color: cs.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: cs.onErrorContainer,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting
              ? null
              : () async {
                  if (!_formKey.currentState!.validate()) return;
                  setState(() {
                    _submitting = true;
                    _error = null;
                  });
                  try {
                    await widget.onSubmit(_ctrl.text.trim());
                    if (!mounted) {
                      return;
                    }
                    Navigator.of(this.context).pop();
                  } catch (e) {
                    setState(() {
                      _error = '加载失败：$e';
                      _submitting = false;
                    });
                  }
                },
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('确认添加'),
        ),
      ],
    );
  }
}
