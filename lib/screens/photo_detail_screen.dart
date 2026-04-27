import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:block_flutter/block_flutter.dart';
import '../models/photo_collection.dart';
import '../providers/connection_provider.dart';
import '../services/block_service.dart';
import '../services/image_service.dart';

class PhotoDetailScreen extends StatefulWidget {
  const PhotoDetailScreen({
    super.key,
    required this.photos,
    required this.initialIndex,
    required this.imageService,
    required this.connectionProvider,
    required this.collections,
  });

  final List<PhotoItem> photos;
  final int initialIndex;
  final ImageService imageService;
  final ConnectionProvider connectionProvider;
  final List<PhotoCollection> collections;

  @override
  State<PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends State<PhotoDetailScreen> {
  late final PageController _pageCtrl;
  late final ScrollController _thumbCtrl;
  late int _current;
  late List<PhotoItem> _photos; // 可变副本，支持本地更新
  final Set<int> _fetched = {}; // 已拉取最新数据的 index

  // UI 显示/隐藏
  bool _uiVisible = true;

  // 下拉关闭 / 上滑信息
  double _dragOffset = 0;
  double _bgOpacity = 1.0;

  // 当前图片缩放比例（1.0 = 未缩放）
  double _currentScale = 1.0;

  // 用于 Listener 追踪原始指针
  Offset? _pointerStart;
  bool _trackingDrag = false;

  static const double _dismissThreshold = 60;
  static const double _thumbSize = 52;
  static const double _thumbSpacing = 3;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _photos = List<PhotoItem>.from(widget.photos);
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchLatest(_current));
    _pageCtrl = PageController(initialPage: widget.initialIndex);
    _thumbCtrl = ScrollController(
      initialScrollOffset: _thumbScrollOffset(widget.initialIndex),
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _thumbCtrl.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _fetchLatest(int index) async {
    if (_fetched.contains(index)) return;
    _fetched.add(index);
    try {
      final service = BlockService(widget.connectionProvider);
      final block = await service.fetchBlock(_photos[index].bid);
      if (mounted) {
        setState(() => _photos[index] = PhotoItem.fromBlock(block));
      }
    } catch (_) {
      // 静默失败，保留旧数据
    }
  }

  double _thumbScrollOffset(int index) {
    // 让选中项尽量居中
    return (index * (_thumbSize + _thumbSpacing)) - 100;
  }

  void _onPageChanged(int i) {
    setState(() => _current = i);
    _fetchLatest(i);
    if (_thumbCtrl.hasClients) {
      _thumbCtrl.animateTo(
        _thumbScrollOffset(i).clamp(0.0, _thumbCtrl.position.maxScrollExtent),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _openInfo() {
    final photo = _photos[_current];
    Navigator.of(context).push<PhotoItem>(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => PhotoInfoScreen(
          photo: photo,
          imageService: widget.imageService,
          connectionProvider: widget.connectionProvider,
          collections: widget.collections,
          onSaved: (updated) {
            if (mounted) setState(() => _photos[_current] = updated);
          },
        ),
        transitionsBuilder: (_, animation, __, child) {
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: child,
          );
        },
      ),
    );
  }

  void _onPointerDown(PointerDownEvent e) {
    // 放大状态下不追踪，让 InteractiveViewer 自由处理
    if (_currentScale > 1.05) {
      _pointerStart = null;
      _trackingDrag = false;
      return;
    }
    _pointerStart = e.position;
    _trackingDrag = false;
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_currentScale > 1.05) return;
    final start = _pointerStart;
    if (start == null) return;

    final total = e.position - start;

    if (!_trackingDrag) {
      // 只要垂直分量 >= 水平分量就接管，不再要求 1.5 倍
      if (total.dy.abs() >= total.dx.abs() && total.dy.abs() > 5) {
        _trackingDrag = true;
      } else if (total.dx.abs() > total.dy.abs() && total.dx.abs() > 5) {
        _pointerStart = null; // 明确水平，放弃
        return;
      } else {
        return; // 还没确定方向
      }
    }

    final dy = e.delta.dy;
    setState(() {
      _uiVisible = false; // 开始拖动就隐藏 UI
      if (dy < 0) {
        _dragOffset = _dragOffset + dy * 0.6;
      } else {
        _dragOffset = (_dragOffset + dy).clamp(0.0, double.infinity);
      }
      _bgOpacity = (1.0 - (_dragOffset.abs() / 300)).clamp(0.15, 1.0);
    });
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!_trackingDrag) {
      _pointerStart = null;
      return;
    }
    _trackingDrag = false;
    _pointerStart = null;

    if (_dragOffset > _dismissThreshold) {
      Navigator.of(context).pop(_current);
      return;
    }
    if (_dragOffset < -60) {
      setState(() {
        _dragOffset = 0;
        _bgOpacity = 1.0;
      });
      _openInfo();
      return;
    }
    // 回弹：不恢复 UI
    setState(() {
      _dragOffset = 0;
      _bgOpacity = 1.0;
    });
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _trackingDrag = false;
    _pointerStart = null;
    setState(() {
      _dragOffset = 0;
      _bgOpacity = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photos[_current];
    final total = _photos.length;

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: _bgOpacity),
      body: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        child: Stack(
          children: [
            // ── 只有图片在 PageView 中左右滑动 ──
            Transform.translate(
              offset: Offset(0, _dragOffset),
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                padding: _uiVisible
                    ? const EdgeInsets.only(top: 80, bottom: 110)
                    : EdgeInsets.zero,
                child: PageView.builder(
                  controller: _pageCtrl,
                  itemCount: total,
                  onPageChanged: _onPageChanged,
                  // 放大时禁用 PageView 翻页，让 InteractiveViewer 接管滑动
                  physics: _currentScale > 1.05
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemBuilder: (context, index) {
                    return Hero(
                      tag: _photos[index].heroTag,
                      child: _PhotoViewer(
                        photo: _photos[index],
                        imageService: widget.imageService,
                        onTap: () => setState(() => _uiVisible = !_uiVisible),
                        onScaleChanged: (scale) {
                          if ((scale - _currentScale).abs() > 0.01) {
                            setState(() => _currentScale = scale);
                          }
                        },
                        onResetScale: () {
                          if (!_uiVisible) setState(() => _uiVisible = true);
                        },
                        onZoomIn: () {
                          if (_uiVisible) setState(() => _uiVisible = false);
                        },
                      ),
                    );
                  },
                ),
              ),
            ),

            // ── 顶部渐变 + 返回 + 标题（固定不动）──
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _uiVisible ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !_uiVisible,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xBB000000), Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                            onPressed: () =>
                                Navigator.of(context).pop(_current),
                          ),
                          Expanded(
                            child: Text(
                              photo.title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (photo.isEncrypted)
                            Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.lock_rounded,
                                      color: Colors.white54,
                                      size: 11,
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      '已加密',
                                      style: TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── 底部渐变 + 缩略图条 + 时间 + 加密状态（固定不动）──
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: _uiVisible ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !_uiVisible,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xDD000000), Colors.transparent],
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 缩略图条（点击进入信息页）
                          GestureDetector(
                            onTap: _openInfo,
                            child: total > 1
                                ? SizedBox(
                                    height: _thumbSize + 8,
                                    child: ListView.builder(
                                      controller: _thumbCtrl,
                                      scrollDirection: Axis.horizontal,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      itemCount: total,
                                      itemExtent: _thumbSize + _thumbSpacing,
                                      itemBuilder: (context, index) {
                                        final isSelected = index == _current;
                                        return GestureDetector(
                                          onTap: () {
                                            _pageCtrl.animateToPage(
                                              index,
                                              duration: const Duration(
                                                milliseconds: 300,
                                              ),
                                              curve: Curves.easeOut,
                                            );
                                          },
                                          child: Padding(
                                            padding: EdgeInsets.only(
                                              right: _thumbSpacing,
                                            ),
                                            child: AnimatedContainer(
                                              duration: const Duration(
                                                milliseconds: 200,
                                              ),
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                border: Border.all(
                                                  color: isSelected
                                                      ? Colors.white
                                                      : Colors.transparent,
                                                  width: 2,
                                                ),
                                              ),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(3),
                                                child: _ThumbnailImage(
                                                  photo: _photos[index],
                                                  imageService:
                                                      widget.imageService,
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  )
                                : const SizedBox(height: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 图片信息页 ────────────────────────────────────────────────

class PhotoInfoScreen extends StatefulWidget {
  const PhotoInfoScreen({
    super.key,
    required this.photo,
    required this.imageService,
    required this.connectionProvider,
    required this.collections,
    this.onSaved,
  });
  final PhotoItem photo;
  final ImageService imageService;
  final ConnectionProvider connectionProvider;
  final List<PhotoCollection> collections;
  final ValueChanged<PhotoItem>? onSaved;

  @override
  State<PhotoInfoScreen> createState() => _PhotoInfoScreenState();
}

class _PhotoInfoScreenState extends State<PhotoInfoScreen> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _introCtrl;
  late final TextEditingController _tagCtrl;
  late List<String> _tags;
  bool _saving = false;
  bool _dirty = false;

  // 所属集合（直接从 block.data['link'] 读取）
  late List<String> _linkedBids;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.photo.title);
    _introCtrl = TextEditingController(text: widget.photo.block.intro ?? '');
    _tagCtrl = TextEditingController();
    _tags = List<String>.from(widget.photo.block.getList<String>('tag'));
    _titleCtrl.addListener(_markDirty);
    _introCtrl.addListener(_markDirty);
    _linkedBids = widget.photo.block.getList<String>('link');
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _introCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  void _markDirty() => setState(() => _dirty = true);

  void _addTag(String tag) {
    final t = tag.trim();
    if (t.isEmpty || _tags.contains(t)) return;
    setState(() {
      _tags.add(t);
      _dirty = true;
    });
  }

  void _showAddTagDialog() {
    _tagCtrl.clear();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加标签'),
        content: TextField(
          controller: _tagCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入标签名称'),
          textInputAction: TextInputAction.done,
          onSubmitted: (v) {
            _addTag(v);
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          FilledButton(
            onPressed: () {
              _addTag(_tagCtrl.text);
              Navigator.of(ctx).pop();
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _removeTag(String t) => setState(() {
    _tags.remove(t);
    _dirty = true;
  });

  void _addLink(String bid) {
    if (_linkedBids.contains(bid)) return;
    setState(() {
      _linkedBids = [..._linkedBids, bid];
      _dirty = true;
    });
  }

  void _removeLink(String bid) {
    if (_linkedBids.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('链接至少保留一个'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() {
      _linkedBids = _linkedBids.where((b) => b != bid).toList();
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (!_dirty) return;
    setState(() => _saving = true);
    try {
      final service = BlockService(widget.connectionProvider);
      final updated = Map<String, dynamic>.from(widget.photo.block.data);
      updated['name'] = _titleCtrl.text.trim();
      updated['intro'] = _introCtrl.text.trim();
      updated['tag'] = _tags;
      updated['link'] = _linkedBids;
      await service.saveBlock(updated);
      // 同步更新本地缓存
      final bid = updated['bid'] as String?;
      if (bid != null) {
        await BlockCache.instance.put(bid, BlockModel(data: updated));
      }
      if (mounted) {
        setState(() {
          _dirty = false;
          _saving = false;
        });
        // 通知外层更新，不关闭页面
        final newItem = PhotoItem.fromBlock(BlockModel(data: updated));
        widget.onSaved?.call(newItem);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  String _formatSize(dynamic raw) {
    final bytes = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (bytes == null || bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatCoord(dynamic v) {
    final d = v is double
        ? v
        : v is int
        ? v.toDouble()
        : double.tryParse(v.toString());
    if (d == null) return v.toString();
    return d.toStringAsFixed(6);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final bg = brightness == Brightness.dark
        ? const Color(0xFF111111)
        : cs.surface;
    final ipfs = widget.photo.block.getMap('ipfs');
    final sizeStr = _formatSize(ipfs['size']);

    // 解析 GPS 数据，兼容多种格式
    String? gpsStr;
    final gpsRaw = ipfs['gps'] ?? widget.photo.block.data['gps'];
    if (gpsRaw is Map) {
      final lat = gpsRaw['lat'] ?? gpsRaw['latitude'];
      final lng = gpsRaw['lng'] ?? gpsRaw['longitude'] ?? gpsRaw['lon'];
      if (lat != null && lng != null) {
        gpsStr = '${_formatCoord(lat)}, ${_formatCoord(lng)}';
      }
    } else if (gpsRaw is String && gpsRaw.trim().isNotEmpty) {
      gpsStr = gpsRaw.trim();
    }

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('图片信息'),
        backgroundColor: bg,
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_dirty)
            TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // 缩略图
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _ThumbnailImage(
              photo: widget.photo,
              imageService: widget.imageService,
              variant: ImageVariant.medium,
            ),
          ),
          const SizedBox(height: 20),

          // 标题
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _titleCtrl,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              decoration: InputDecoration(
                labelText: '标题',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                isDense: true,
              ),
              textInputAction: TextInputAction.next,
            ),
          ),
          const SizedBox(height: 14),

          // 介绍
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _introCtrl,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: '介绍',
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // 标签
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '标签',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // 已有标签
                    ..._tags.map(
                      (t) => Chip(
                        label: Text(
                          t,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onPrimaryContainer,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        deleteIcon: Icon(
                          Icons.close_rounded,
                          size: 13,
                          color: cs.onPrimaryContainer.withValues(alpha: 0.6),
                        ),
                        onDeleted: () => _removeTag(t),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: cs.primaryContainer,
                        side: BorderSide.none,
                      ),
                    ),
                    // + 添加标签（虚线边框）
                    _DashedChip(
                      label: '+ 添加标签',
                      color: cs.primary,
                      onTap: _showAddTagDialog,
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          Divider(
            height: 1,
            indent: 20,
            endIndent: 20,
            color: cs.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),

          // 元数据
          if (widget.photo.time.isNotEmpty)
            _MetaRow(
              icon: Icons.access_time_rounded,
              label: '时间',
              value: widget.photo.time,
            ),
          if (sizeStr.isNotEmpty)
            _MetaRow(
              icon: Icons.data_usage_rounded,
              label: '大小',
              value: sizeStr,
            ),
          if (gpsStr != null)
            _MetaRow(
              icon: Icons.location_on_rounded,
              label: 'GPS',
              value: gpsStr,
              selectable: true,
            ),
          _MetaRow(
            icon: widget.photo.isEncrypted
                ? Icons.lock_rounded
                : Icons.lock_open_rounded,
            label: '加密',
            value: widget.photo.isEncrypted
                ? '已加密（${widget.photo.encryptionAlgo}）'
                : '未加密',
            valueColor: widget.photo.isEncrypted
                ? cs.primary
                : cs.onSurfaceVariant,
          ),
          _LinkRows(
            bids: _linkedBids,
            collections: widget.collections,
            onAdd: _addLink,
            onDelete: _removeLink,
          ),
          _MetaRow(
            icon: Icons.tag_rounded,
            label: 'BID',
            value: widget.photo.bid,
            mono: true,
            selectable: true,
          ),
        ],
      ),
    );
  }
}

class _DashedChip extends StatelessWidget {
  const _DashedChip({
    required this.label,
    required this.color,
    required this.onTap,
  });
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedBorderPainter(color: color),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(label, style: TextStyle(fontSize: 12, color: color)),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    const radius = Radius.circular(16);
    final rRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      radius,
    );

    const dashWidth = 4.0;
    const dashSpace = 3.0;
    final path = Path()..addRRect(rRect);
    final metrics = path.computeMetrics();

    for (final metric in metrics) {
      double distance = 0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, distance + dashWidth),
          paint,
        );
        distance += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

class _LinkRows extends StatelessWidget {
  const _LinkRows({
    required this.bids,
    required this.collections,
    required this.onAdd,
    required this.onDelete,
  });
  final List<String> bids;
  final List<PhotoCollection> collections;
  final void Function(String bid) onAdd;
  final void Function(String bid) onDelete;

  void _showLongPressSheet(BuildContext context, String bid) {
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
              Text(
                bid,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurfaceVariant,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 4),
              ListTile(
                leading: Icon(Icons.copy_rounded, color: cs.onSurfaceVariant),
                title: const Text('复制 BID'),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: bid));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制 BID'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                leading: Icon(Icons.link_off_rounded, color: cs.error),
                title: Text('删除链接', style: TextStyle(color: cs.error)),
                onTap: () {
                  Navigator.pop(context);
                  onDelete(bid);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddSheet(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unknownBids = bids
        .where((b) => !collections.any((c) => c.bid == b))
        .toList();

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        // sheet 内独立维护当前已链接状态，不依赖外部 bids 实时更新
        var linked = Set<String>.from(bids);
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void toggle(String bid) {
              if (linked.contains(bid)) {
                if (linked.length <= 1) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('链接至少保留一个'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                  return;
                }
                onDelete(bid);
                setSheetState(() => linked = Set.from(linked)..remove(bid));
              } else {
                onAdd(bid);
                setSheetState(() => linked = Set.from(linked)..add(bid));
              }
            }

            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.fromLTRB(0, 12, 0, 8),
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '链接',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 400),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        if (collections.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                            child: Text(
                              '本地集合',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          ...collections.map((col) {
                            final isLinked = linked.contains(col.bid);
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              leading: Icon(
                                Icons.folder_rounded,
                                color: isLinked
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                              title: Text(
                                col.title ?? col.bid,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                col.bid.length > 20
                                    ? '${col.bid.substring(0, 8)}…${col.bid.substring(col.bid.length - 4)}'
                                    : col.bid,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              trailing: Icon(
                                isLinked
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                color: isLinked
                                    ? cs.primary
                                    : cs.onSurfaceVariant.withValues(
                                        alpha: 0.5,
                                      ),
                              ),
                              onTap: () => toggle(col.bid),
                            );
                          }),
                        ],
                        if (unknownBids.isNotEmpty) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                            child: Text(
                              '其他链接',
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.onSurfaceVariant,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          ...unknownBids.map((bid) {
                            final isLinked = linked.contains(bid);
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              leading: Icon(
                                Icons.link_rounded,
                                color: isLinked
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                              title: Text(
                                bid,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Icon(
                                isLinked
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked_rounded,
                                color: isLinked
                                    ? cs.primary
                                    : cs.onSurfaceVariant.withValues(
                                        alpha: 0.5,
                                      ),
                              ),
                              onTap: () => toggle(bid),
                            );
                          }),
                        ],
                        if (collections.isEmpty && unknownBids.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              '没有可用的集合',
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.link_rounded, size: 16, color: cs.primary),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '链接',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...bids.map((bid) {
                  final match = collections
                      .where((c) => c.bid == bid)
                      .firstOrNull;
                  return GestureDetector(
                    onLongPress: () => _showLongPressSheet(context, bid),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: match != null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  match.title ?? bid,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: cs.onSurface,
                                  ),
                                ),
                                Text(
                                  bid,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              bid,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface,
                                fontFamily: 'monospace',
                              ),
                            ),
                    ),
                  );
                }),
                GestureDetector(
                  onTap: () => _showAddSheet(context),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_rounded,
                          size: 14,
                          color: cs.primary.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '选择集合',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.primary.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.icon,
    required this.label,
    required this.value,
    this.mono = false,
    this.selectable = false,
    this.valueColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool mono;
  final bool selectable;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = TextStyle(
      fontSize: 14,
      fontFamily: mono ? 'monospace' : null,
      color: valueColor ?? cs.onSurface,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 12),
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: selectable
                ? SelectableText(value, style: style)
                : Text(value, style: style),
          ),
        ],
      ),
    );
  }
}

// ── 缩略图 ────────────────────────────────────────────────────

class _ThumbnailImage extends StatefulWidget {
  const _ThumbnailImage({
    required this.photo,
    required this.imageService,
    this.variant = ImageVariant.squareThumb,
  });
  final PhotoItem photo;
  final ImageService imageService;
  final ImageVariant variant;

  @override
  State<_ThumbnailImage> createState() => _ThumbnailImageState();
}

class _ThumbnailImageState extends State<_ThumbnailImage> {
  Uint8List? _bytes;
  int _loadSerial = 0;

  @override
  void initState() {
    super.initState();
    _loadFromCacheOrNetwork();
  }

  @override
  void didUpdateWidget(_ThumbnailImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.cid != widget.photo.cid ||
        oldWidget.variant != widget.variant) {
      _bytes = null;
      _loadFromCacheOrNetwork();
    }
  }

  void _loadFromCacheOrNetwork() {
    // 优先内存缓存，避免重复网络请求
    _bytes =
        ImageCacheHelper.getMemoryImage(
          widget.photo.cid,
          variant: widget.variant,
        ) ??
        ImageCacheHelper.getMemoryImage(
          widget.photo.cid,
          variant: ImageVariant.small,
        ) ??
        ImageCacheHelper.getMemoryImage(
          widget.photo.cid,
          variant: ImageVariant.medium,
        );
    if (_bytes == null) _load();
  }

  Future<void> _load() async {
    final serial = ++_loadSerial;
    final cid = widget.photo.cid;
    final bytes = await widget.imageService.loadImage(
      widget.photo,
      variant: widget.variant,
    );
    if (mounted &&
        serial == _loadSerial &&
        widget.photo.cid == cid &&
        bytes != null) {
      setState(() => _bytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return const ColoredBox(
        color: Color(0xFF222222),
        child: SizedBox.expand(),
      );
    }
    return Image.memory(
      _bytes!,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      gaplessPlayback: true,
    );
  }
}

// ── 图片查看器 ────────────────────────────────────────────────

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({
    required this.photo,
    required this.imageService,
    this.onTap,
    this.onScaleChanged,
    this.onResetScale,
    this.onZoomIn,
  });
  final PhotoItem photo;
  final ImageService imageService;
  final VoidCallback? onTap;
  final ValueChanged<double>? onScaleChanged;
  // 缩放恢复到 1x 时回调
  final VoidCallback? onResetScale;
  // 放大时回调
  final VoidCallback? onZoomIn;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer>
    with SingleTickerProviderStateMixin {
  Uint8List? _bytes;
  bool _loading = true;
  bool _error = false;
  int _loadSerial = 0;
  final TransformationController _transformCtrl = TransformationController();
  late final AnimationController _animCtrl;
  Animation<Matrix4>? _animation;

  static const double _zoomScale = 2.5;

  @override
  void initState() {
    super.initState();
    _loadFromCacheOrNetwork();
    _transformCtrl.addListener(_onTransformChanged);
    _animCtrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 250),
        )..addListener(() {
          if (_animation != null) _transformCtrl.value = _animation!.value;
        });
  }

  @override
  void didUpdateWidget(_PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.cid != widget.photo.cid) {
      _transformCtrl.value = Matrix4.identity();
      _loadFromCacheOrNetwork();
    }
  }

  @override
  void dispose() {
    _transformCtrl.removeListener(_onTransformChanged);
    _transformCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  void _loadFromCacheOrNetwork() {
    _bytes =
        ImageCacheHelper.getMemoryImage(
          widget.photo.cid,
          variant: ImageVariant.small,
        ) ??
        ImageCacheHelper.getMemoryImage(
          widget.photo.cid,
          variant: ImageVariant.medium,
        );
    _loading = _bytes == null;
    _error = false;
    _load();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    final currentScale = _transformCtrl.value.getMaxScaleOnAxis();
    final Matrix4 target;

    if (currentScale > 1.05) {
      // 已放大 → 回到初始
      target = Matrix4.identity();
    } else {
      // 初始大小 → 以点击位置为中心放大
      final pos = details.localPosition;
      target = Matrix4.identity()
        ..translateByDouble(
          -pos.dx * (_zoomScale - 1),
          -pos.dy * (_zoomScale - 1),
          0,
          1,
        )
        ..scaleByDouble(_zoomScale, _zoomScale, 1, 1);
      widget.onZoomIn?.call(); // 通知父级隐藏 UI
    }

    _animation = Matrix4Tween(
      begin: _transformCtrl.value,
      end: target,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));

    _animCtrl.forward(from: 0);
  }

  void _onTransformChanged() {
    // 从变换矩阵中提取缩放比例
    final scale = _transformCtrl.value.getMaxScaleOnAxis();
    widget.onScaleChanged?.call(scale);
    // 缩放回到初始大小时通知父级显示 UI
    if (scale <= 1.01) {
      widget.onResetScale?.call();
    }
  }

  Future<void> _load() async {
    final serial = ++_loadSerial;
    final cid = widget.photo.cid;
    try {
      final bytes = await widget.imageService.loadImage(
        widget.photo,
        variant: ImageVariant.original,
      );
      if (mounted && serial == _loadSerial && widget.photo.cid == cid) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted && serial == _loadSerial && widget.photo.cid == cid) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: CircularProgressIndicator(
            color: Colors.white54,
            strokeWidth: 2,
          ),
        ),
      );
    }
    if (_bytes == null || _error) {
      return ColoredBox(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                color: Colors.white24,
                size: 56,
              ),
              const SizedBox(height: 12),
              Text(
                '图片加载失败',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: GestureDetector(
        onTap: widget.onTap,
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: () {}, // 必须声明才能触发 onDoubleTapDown
        child: InteractiveViewer(
          transformationController: _transformCtrl,
          minScale: 0.5,
          maxScale: 5.0,
          child: Center(
            child: Image.memory(
              _bytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}
