import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/photo_collection.dart';
import '../providers/connection_provider.dart';
import '../providers/photo_provider.dart';
import '../services/upload_service.dart';

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  File? _selectedFile;
  Uint8List? _previewBytes;
  final _nameController = TextEditingController();
  final _introController = TextEditingController();
  final _tagController = TextEditingController();
  final List<String> _tags = [];
  Set<String> _selectedCollectionBids = {};
  int _permissionLevel = 0;
  bool _encrypt = true;
  bool _uploading = false;
  String _status = '';

  // 从文件提取的元数据
  DateTime? _photoTime;
  Map<String, double>? _photoGps;

  @override
  void dispose() {
    _nameController.dispose();
    _introController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final connProvider = context.read<ConnectionProvider>();

    try {
      // Android 上必须运行时请求 ACCESS_MEDIA_LOCATION 才能读到 EXIF GPS
      if (Platform.isAndroid) {
        await Permission.accessMediaLocation.request();
        // 同时确保有相册读取权限
        final photos = await Permission.photos.status;
        if (!photos.isGranted && !photos.isLimited) {
          await Permission.photos.request();
        }
      }

      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: !Platform.isMacOS,
      );
      if (picked == null) return;

      // 直接从 XFile 读取字节（Android 上会从原始 URI 读取，保留 EXIF）
      final bytes = await picked.readAsBytes();

      // 用字节写入临时文件供后续上传使用
      final file = File(picked.path);

      // XFile.lastModified() 在 Android 上读 content URI 的 DATE_MODIFIED，比文件系统时间准确
      DateTime? xfileTime;
      try {
        xfileTime = await picked.lastModified();
      } catch (_) {}

      // 提取元数据：直接传字节给解析器，避免文件系统时间被污染
      final meta = await UploadService(connProvider).extractMetaFromBytes(
        bytes: bytes,
        path: picked.path,
        originalFile: file,
        fallbackTime: xfileTime,
      );

      setState(() {
        _selectedFile = file;
        _previewBytes = bytes;
        _photoTime = meta.timestamp;
        _photoGps = meta.gps;
        if (_nameController.text.isEmpty) {
          _nameController.text = meta.name;
        }
      });
    } catch (e) {
      _showSnack('选择图片失败：$e');
    }
  }

  Future<void> _upload() async {
    if (_selectedFile == null) {
      _showSnack('请先选择图片');
      return;
    }
    if (_selectedCollectionBids.isEmpty) {
      _showSnack('请至少选择一个集合');
      return;
    }

    setState(() {
      _uploading = true;
      _status = '准备上传...';
    });

    try {
      final service = UploadService(context.read<ConnectionProvider>());
      await service.uploadPhoto(
        file: _selectedFile!,
        fileBytes: _previewBytes,
        collectionBids: _selectedCollectionBids.toList(),
        name: _nameController.text.trim(),
        intro: _introController.text.trim(),
        tags: _tags,
        permissionLevel: _permissionLevel,
        encrypt: _encrypt,
        onStatus: (s) {
          if (mounted) setState(() => _status = s);
        },
      );
      if (!mounted) return;
      _showSnack('上传成功');
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      _showSnack('上传失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  void _addTag(String tag) {
    final t = tag.trim();
    if (t.isEmpty || _tags.contains(t)) return;
    setState(() {
      _tags.add(t);
    });
  }

  void _removeTag(String t) => setState(() => _tags.remove(t));

  void _showAddTagDialog() {
    _tagController.clear();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加标签'),
        content: TextField(
          controller: _tagController,
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
              _addTag(_tagController.text);
              Navigator.of(ctx).pop();
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showCollectionSheet(List<PhotoCollection> collections) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        var linked = Set<String>.from(_selectedCollectionBids);
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void toggle(String bid) {
              setSheetState(() {
                if (linked.contains(bid)) {
                  linked = Set.from(linked)..remove(bid);
                } else {
                  linked = Set.from(linked)..add(bid);
                }
              });
              setState(() => _selectedCollectionBids = Set.from(linked));
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
                        '选择集合',
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
                      children: collections.isEmpty
                          ? [
                              Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  '没有可用的集合',
                                  style: TextStyle(color: cs.onSurfaceVariant),
                                ),
                              ),
                            ]
                          : collections.map((col) {
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
                            }).toList(),
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
    final collections = context.watch<PhotoProvider>().collections;

    return Scaffold(
      appBar: AppBar(
        title: const Text('上传图片'),
        actions: [
          if (_uploading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(onPressed: _upload, child: const Text('上传')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          // 图片预览 / 选择区域
          GestureDetector(
            onTap: _uploading ? null : _pickImage,
            child: Container(
              height: 220,
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _selectedFile == null
                      ? cs.outlineVariant
                      : cs.primary.withValues(alpha: 0.4),
                  width: _selectedFile == null ? 1.5 : 2,
                ),
              ),
              child: _previewBytes != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.memory(
                        _previewBytes!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                      ),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 48,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '点击选择图片',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 20),

          // 时间 & GPS 元数据（选图后显示）
          if (_photoTime != null || _photoGps != null) ...[
            if (_photoTime != null)
              _MetaInfoRow(
                icon: Icons.access_time_rounded,
                label: '时间',
                value: _formatDateTime(_photoTime!),
              ),
            if (_photoGps != null)
              _MetaInfoRow(
                icon: Icons.location_on_rounded,
                label: 'GPS',
                value:
                    '${_photoGps!['latitude']!.toStringAsFixed(6)}, '
                    '${_photoGps!['longitude']!.toStringAsFixed(6)}',
              ),
            const SizedBox(height: 12),
          ],

          // 名称
          TextField(
            controller: _nameController,
            enabled: !_uploading,
            decoration: InputDecoration(
              labelText: '图片名称',
              hintText: '可选，默认使用文件名',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              prefixIcon: const Icon(Icons.title_rounded),
            ),
          ),
          const SizedBox(height: 12),

          // 介绍
          TextField(
            controller: _introController,
            enabled: !_uploading,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: '介绍',
              hintText: '可选',
              alignLabelWithHint: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              prefixIcon: const Padding(
                padding: EdgeInsets.only(bottom: 40),
                child: Icon(Icons.notes_rounded),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 标签
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
                  onDeleted: _uploading ? null : () => _removeTag(t),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: cs.primaryContainer,
                  side: BorderSide.none,
                ),
              ),
              if (!_uploading)
                _DashedChip(
                  label: '+ 添加标签',
                  color: cs.primary,
                  onTap: _showAddTagDialog,
                ),
            ],
          ),
          const SizedBox(height: 20),

          // 集合选择
          Text(
            '集合',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          if (_selectedCollectionBids.isEmpty)
            GestureDetector(
              onTap: _uploading
                  ? null
                  : () => _showCollectionSheet(collections),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add_rounded,
                      size: 14,
                      color: cs.error.withValues(alpha: 0.8),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '必须选择至少一个集合',
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.error.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            ...() {
              final selectedCols = collections
                  .where((c) => _selectedCollectionBids.contains(c.bid))
                  .toList();
              final unknownBids = _selectedCollectionBids
                  .where((b) => !collections.any((c) => c.bid == b))
                  .toList();
              return [
                ...selectedCols.map(
                  (col) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Icon(Icons.folder_rounded, size: 15, color: cs.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                col.title ?? col.bid,
                                style: const TextStyle(fontSize: 14),
                              ),
                              Text(
                                col.bid.length > 20
                                    ? '${col.bid.substring(0, 8)}…${col.bid.substring(col.bid.length - 4)}'
                                    : col.bid,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ...unknownBids.map(
                  (bid) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Icon(Icons.link_rounded, size: 15, color: cs.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            bid,
                            style: TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              color: cs.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ];
            }(),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: _uploading
                  ? null
                  : () => _showCollectionSheet(collections),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.edit_rounded,
                    size: 14,
                    color: cs.primary.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '修改集合',
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.primary.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),

          // 权限等级
          Text(
            '权限等级',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          _PermissionSelector(
            value: _permissionLevel,
            enabled: !_uploading,
            onChanged: (v) => setState(() => _permissionLevel = v),
          ),
          const SizedBox(height: 20),

          // 加密开关
          SwitchListTile(
            value: _encrypt,
            onChanged: _uploading ? null : (v) => setState(() => _encrypt = v),
            title: const Text('加密上传'),
            subtitle: const Text('使用 AES-GCM 加密文件内容'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            contentPadding: EdgeInsets.zero,
          ),

          // 上传状态
          if (_uploading && _status.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(_status, style: TextStyle(color: cs.onSurfaceVariant)),
              ],
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── 权限等级选择器 ─────────────────────────────────────────────

class _PermissionSelector extends StatelessWidget {
  const _PermissionSelector({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final bool enabled;

  static const _levels = [
    (value: 0, label: '等级 0', desc: '私有，最高保护', color: Color(0xFFAB47BC)),
    (value: 1, label: '等级 1', desc: '公开访问', color: Color(0xFF4CAF50)),
    (value: 2, label: '等级 2', desc: '团队共享', color: Color(0xFF26C6DA)),
    (value: 3, label: '等级 3', desc: '受控访问', color: Color(0xFFFFB300)),
    (value: 4, label: '等级 4', desc: '核心保密', color: Color(0xFFE53935)),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = _levels.firstWhere(
      (l) => l.value == value,
      orElse: () => _levels.first,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _levels.map((level) {
            final isSelected = value == level.value;
            return GestureDetector(
              onTap: enabled ? () => onChanged(level.value) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? level.color.withValues(alpha: 0.12)
                      : cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected ? level.color : cs.outlineVariant,
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
                child: Text(
                  level.label,
                  style: TextStyle(
                    fontSize: 13,
                    color: isSelected ? level.color : cs.onSurfaceVariant,
                    fontWeight: isSelected
                        ? FontWeight.w600
                        : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: selected.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              selected.desc,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

// ── 虚线边框 Chip（与 photo_detail_screen 一致）─────────────────

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

    for (final metric in path.computeMetrics()) {
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

// ── 元数据展示行 ───────────────────────────────────────────────

class _MetaInfoRow extends StatelessWidget {
  const _MetaInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 13, color: cs.onSurface),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
