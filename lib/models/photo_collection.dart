import 'package:block_flutter/block_flutter.dart';

class PhotoCollection {
  PhotoCollection({
    required this.bid,
    required Map<String, dynamic> block,
    this.isAlbum = false,
    this.isDefault = false,
  }) : _block = Map.unmodifiable(Map<String, dynamic>.from(block));

  PhotoCollection._internal({
    required this.bid,
    required Map<String, dynamic> block,
    required this.isAlbum,
    required this.isDefault,
  }) : _block = Map.unmodifiable(block);

  final String bid;
  final Map<String, dynamic> _block;
  final bool isAlbum;
  final bool isDefault;

  String? get title => (_block['name'] as String?)?.trim();
  Map<String, dynamic> get block => Map<String, dynamic>.from(_block);

  /// link_tag 标签列表
  List<String> get linkTags {
    final raw = _block['link_tag'];
    if (raw is List) {
      return raw.whereType<String>().where((s) => s.trim().isNotEmpty).toList();
    }
    return [];
  }

  PhotoCollection copyWith({
    String? bid,
    Map<String, dynamic>? block,
    bool? isAlbum,
    bool? isDefault,
  }) {
    return PhotoCollection._internal(
      bid: bid ?? this.bid,
      block: block != null
          ? Map<String, dynamic>.from(block)
          : Map<String, dynamic>.from(_block),
      isAlbum: isAlbum ?? this.isAlbum,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toJson() => {
    'bid': bid,
    'block': _block,
    'isAlbum': isAlbum,
    'isDefault': isDefault,
  };

  factory PhotoCollection.fromJson(Map<String, dynamic> json) {
    final rawBlock = json['block'];
    final blockMap = rawBlock is Map<String, dynamic>
        ? Map<String, dynamic>.from(rawBlock)
        : <String, dynamic>{};
    final resolvedBid =
        (json['bid'] as String?) ?? (blockMap['bid'] as String?) ?? '';
    return PhotoCollection._internal(
      bid: resolvedBid,
      block: blockMap,
      isAlbum: json['isAlbum'] as bool? ?? false,
      isDefault: json['isDefault'] as bool? ?? false,
    );
  }
}

/// 图片数据，包含 block 信息和加载状态
class PhotoItem {
  PhotoItem({
    required this.block,
    required this.cid,
    required this.bid,
    required this.title,
    required this.time,
    this.ext,
    this.encryptionAlgo,
    this.encryptionKey,
  });

  factory PhotoItem.fromBlock(BlockModel block) {
    final ipfs = block.getMap('ipfs');
    final cid = (ipfs['cid'] as String?)?.trim() ?? '';
    final bid = block.maybeString('bid') ?? cid;
    final title =
        block.maybeString('name') ?? block.maybeString('fileName') ?? '图片';
    final createdAt =
        block.getDateTime('add_time') ?? block.getDateTime('createdAt');
    final time = createdAt != null ? _formatDate(createdAt) : '';
    final ext = ipfs['ext'] as String?;

    String? encAlgo;
    String? encKey;
    final encMap = ipfs['encryption'];
    if (encMap is Map<String, dynamic>) {
      encAlgo = encMap['algo'] as String?;
      encKey = encMap['key'] as String?;
    }

    return PhotoItem(
      block: block,
      cid: cid,
      bid: bid,
      title: title,
      time: time,
      ext: ext,
      encryptionAlgo: encAlgo,
      encryptionKey: encKey,
    );
  }

  final BlockModel block;
  final String cid;
  final String bid;
  final String title;
  final String time;
  final String? ext;
  final String? encryptionAlgo;
  final String? encryptionKey;

  bool get isEncrypted => encryptionAlgo == 'PPE-001' && encryptionKey != null;

  PhotoItem copyWithBlock(BlockModel newBlock) {
    return PhotoItem.fromBlock(newBlock);
  }

  bool get isImage {
    if (ext == null) return true; // 默认当图片处理
    const imageExts = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.JPG',
      '.JPEG',
      '.PNG',
      '.GIF',
      '.WEBP',
      '.BMP',
    ];
    return imageExts.contains(ext);
  }

  String get heroTag => cid.isNotEmpty ? 'cid://$cid' : 'bid://$bid';

  static String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
