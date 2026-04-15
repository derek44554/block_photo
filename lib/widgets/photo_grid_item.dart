import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:block_flutter/block_flutter.dart';
import '../models/photo_collection.dart';
import '../services/image_service.dart';

class PhotoGridItem extends StatefulWidget {
  const PhotoGridItem({
    super.key,
    required this.photo,
    required this.imageService,
    this.onTap,
  });

  final PhotoItem photo;
  final ImageService imageService;
  final VoidCallback? onTap;

  @override
  State<PhotoGridItem> createState() => _PhotoGridItemState();
}

class _PhotoGridItemState extends State<PhotoGridItem>
    with SingleTickerProviderStateMixin {
  Uint8List? _bytes;
  bool _loading = true;
  late final AnimationController _shimmerCtrl;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _load();
  }

  @override
  void didUpdateWidget(PhotoGridItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo.cid != widget.photo.cid) {
      _bytes = null;
      _loading = true;
      _load();
    }
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 先检查内存缓存，命中则直接显示无需等待
    final mem = ImageCacheHelper.getMemoryImage(
      widget.photo.cid,
      variant: ImageVariant.squareThumb,
    );
    if (mem != null) {
      if (mounted) {
        setState(() {
          _bytes = mem;
          _loading = false;
        });
      }
      return;
    }
    final bytes = await widget.imageService.loadImage(
      widget.photo,
      variant: ImageVariant.squareThumb,
    );
    if (mounted) {
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    final radius = isMac ? 12.0 : 0.0;

    return GestureDetector(
      onTap: widget.onTap,
      child: Hero(
        tag: widget.photo.heroTag,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: _loading
              ? _ShimmerBox(controller: _shimmerCtrl)
              : _bytes != null
              ? Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true)
              : Container(
                  color: cs.surfaceContainerLow,
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.3),
                    size: 24,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ShimmerBox extends StatelessWidget {
  const _ShimmerBox({required this.controller});
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8);
    final highlight = isDark
        ? const Color(0xFF3A3A3A)
        : const Color(0xFFF5F5F5);

    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1.5 + controller.value * 3, 0),
              end: Alignment(-0.5 + controller.value * 3, 0),
              colors: [base, highlight, base],
            ),
          ),
        );
      },
    );
  }
}
