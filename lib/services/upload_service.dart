import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:exif/exif.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:block_flutter/block_flutter.dart';

import '../providers/connection_provider.dart';

const _fileModelId = 'c4238dd0d3d95db7b473adb449f6d282';

class UploadService {
  UploadService(this._connectionProvider);

  final ConnectionProvider _connectionProvider;

  /// 上传图片并创建 Block
  Future<BlockModel> uploadPhoto({
    required File file,
    Uint8List? fileBytes,
    required List<String> collectionBids,
    String name = '',
    String intro = '',
    List<String> tags = const [],
    int permissionLevel = 0,
    bool encrypt = true,
    void Function(String status)? onStatus,
  }) async {
    final connection = _connectionProvider.activeConnection;
    if (connection == null) throw Exception('当前没有可用的连接');
    if (connection.address.isEmpty) throw Exception('节点地址无效');

    final nodeData = connection.nodeData;
    final nodeBid = nodeData != null
        ? (nodeData['sender'] as String? ?? '')
        : '';
    if (nodeBid.length < 10) throw Exception('无效的节点 BID: $nodeBid');

    // 1. 读取字节（优先用传入的，保留完整 EXIF）
    onStatus?.call('读取文件信息...');
    final bytes = fileBytes ?? await file.readAsBytes();

    // 2. 提取元数据
    final meta = await extractMetaFromBytes(
      bytes: bytes,
      path: file.path,
      originalFile: file,
    );
    final displayName = name.isNotEmpty ? name : meta.name;

    // 3. 上传到 IPFS
    onStatus?.call('上传到 IPFS...');
    final uploadUrl = Uri.parse(
      connection.address,
    ).replace(path: '/ipfs/ipfs/upload').toString();
    final ipfsData = await _uploadBytes(
      bytes: bytes,
      endpoint: uploadUrl,
      encrypt: encrypt,
      ext: meta.ext,
      nodeKeyBase64: connection.keyBase64,
    );

    // 4. 缓存预览
    final cid = ipfsData['cid'] as String?;
    if (cid != null && cid.isNotEmpty) {
      try {
        await ImageCacheHelper.removeFromCache(cid);
        ImageCacheHelper.cacheMemoryImage(
          cid,
          bytes,
          variant: ImageVariant.original,
        );
      } catch (_) {}
    }

    // 5. 构建并保存 Block
    onStatus?.call('保存 Block...');
    final bid = generateBidV2(nodeBid);
    final blockData = <String, dynamic>{
      'bid': bid,
      'node_bid': nodeBid,
      'model': _fileModelId,
      'name': displayName,
      'intro': intro,
      'tag': tags,
      'link': collectionBids,
      'permission_level': permissionLevel,
      'ipfs': ipfsData,
      'add_time': iso8601WithOffset(meta.timestamp),
    };

    if (meta.gps != null) {
      blockData['gps'] = meta.gps;
    }

    final api = BlockApi(connection: connection);
    await api.saveBlock(data: blockData, receiverBid: nodeBid);

    return BlockModel(data: blockData);
  }

  // ── IPFS 上传（从字节）──────────────────────────────────────

  Future<Map<String, dynamic>> _uploadBytes({
    required Uint8List bytes,
    required String endpoint,
    required bool encrypt,
    required String ext,
    required String nodeKeyBase64,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final payload = _BytesPayload(
      bytes: bytes,
      encrypt: encrypt,
      tempDirPath: tempDir.path,
    );

    final result = await Isolate.run(() => _processBytesPayload(payload));
    final tempPath = result.tempPath;
    try {
      final password = IpfsPasswordHelper.computeUploadPassword(nodeKeyBase64);
      final request = http.MultipartRequest('POST', Uri.parse(endpoint))
        ..fields['password'] = password
        ..files.add(
          await http.MultipartFile.fromPath('file', result.uploadPath),
        );

      final response = await request.send();
      final body = await response.stream.bytesToString();
      if (response.statusCode != 200) {
        throw Exception('上传失败(${response.statusCode}): $body');
      }

      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final cid = decoded['cid'];
      if (cid is! String || cid.isEmpty) throw Exception('响应缺少 cid 字段');

      final resolvedExt = ext.isNotEmpty
          ? (ext.startsWith('.') ? ext : '.$ext')
          : '';
      final ipfsData = <String, dynamic>{
        'cid': cid,
        'ext': resolvedExt,
        'size': result.fileSize,
      };
      if (result.encryptionKeyHex != null) {
        ipfsData['encryption'] = {
          'algo': 'PPE-001',
          'key': result.encryptionKeyHex,
        };
      }
      return ipfsData;
    } finally {
      if (tempPath != null) {
        try {
          await File(tempPath).delete();
        } catch (_) {}
      }
    }
  }

  // ── 元数据提取 ─────────────────────────────────────────────

  Future<FileMeta> extractMeta(File file) async {
    final bytes = await file.readAsBytes();
    return extractMetaFromBytes(
      bytes: bytes,
      path: file.path,
      originalFile: file,
    );
  }

  Future<FileMeta> extractMetaFromBytes({
    required Uint8List bytes,
    required String path,
    File? originalFile,
    DateTime? fallbackTime, // XFile.lastModified()，比文件系统时间更可靠
  }) async {
    final fileName = p.basenameWithoutExtension(path);
    final ext = p.extension(path);

    DateTime? exifTime;
    Map<String, double>? gps;

    try {
      final exifData = await readExifFromBytes(bytes);

      final dateTimeOriginal = exifData['EXIF DateTimeOriginal']?.toString();
      if (dateTimeOriginal != null) {
        final formatted = dateTimeOriginal
            .replaceFirst(':', '-')
            .replaceFirst(':', '-');
        exifTime = DateTime.tryParse(formatted);
      }

      gps = _extractGps(exifData);
    } catch (_) {}

    // 时间优先级：EXIF 拍摄时间 > fallbackTime > 文件系统时间 > 当前时间
    DateTime timestamp;
    if (exifTime != null) {
      timestamp = exifTime;
    } else if (fallbackTime != null) {
      timestamp = fallbackTime;
    } else {
      DateTime? fsTime;
      try {
        final f = originalFile ?? File(path);
        final stat = await f.stat();
        final changed = stat.changed;
        final modified = stat.modified;
        fsTime = changed.isBefore(modified) ? changed : modified;
      } catch (_) {}
      timestamp = fsTime ?? DateTime.now();
    }

    return FileMeta(name: fileName, ext: ext, timestamp: timestamp, gps: gps);
  }

  Map<String, double>? _extractGps(Map<String, IfdTag> data) {
    try {
      final latRef = data['GPS GPSLatitudeRef']?.toString();
      final lonRef = data['GPS GPSLongitudeRef']?.toString();
      final latRatios = data['GPS GPSLatitude']?.values;
      final lonRatios = data['GPS GPSLongitude']?.values;

      if (latRef == null ||
          lonRef == null ||
          latRatios == null ||
          lonRatios == null) {
        return null;
      }

      final lat = _convertGps(latRatios, latRef);
      final lon = _convertGps(lonRatios, lonRef);
      if (lat == null || lon == null) return null;

      return {'latitude': lat, 'longitude': lon};
    } catch (_) {
      return null;
    }
  }

  double? _convertGps(IfdValues values, String ref) {
    try {
      final ratios = values.toList();
      if (ratios.length < 3) return null;

      double toDeg(dynamic r) {
        if (r is Ratio) {
          if (r.denominator == 0) return 0.0;
          return r.numerator / r.denominator;
        }
        return (r as num).toDouble();
      }

      final d = toDeg(ratios[0]);
      final m = toDeg(ratios[1]);
      final s = toDeg(ratios[2]);
      var coord = d + m / 60.0 + s / 3600.0;
      if (ref == 'S' || ref == 'W') coord = -coord;
      return coord;
    } catch (_) {
      return null;
    }
  }
}

// ── 数据类 ─────────────────────────────────────────────────────

class FileMeta {
  const FileMeta({
    required this.name,
    required this.ext,
    required this.timestamp,
    this.gps,
  });
  final String name;
  final String ext;
  final DateTime timestamp;
  final Map<String, double>? gps;
}

class _BytesPayload {
  const _BytesPayload({
    required this.bytes,
    required this.encrypt,
    required this.tempDirPath,
  });
  final Uint8List bytes;
  final bool encrypt;
  final String tempDirPath;
}

class _UploadResult {
  const _UploadResult({
    required this.uploadPath,
    required this.fileSize,
    this.tempPath,
    this.encryptionKeyHex,
  });
  final String uploadPath;
  final int fileSize;
  final String? tempPath;
  final String? encryptionKeyHex;
}

// ── Isolate 任务 ───────────────────────────────────────────────

Future<_UploadResult> _processBytesPayload(_BytesPayload payload) async {
  final bytes = payload.bytes;

  if (!payload.encrypt) {
    // 写入临时文件供 MultipartFile 使用
    final tempPath = p.join(
      payload.tempDirPath,
      'raw_${DateTime.now().microsecondsSinceEpoch}_${_randomHex(8)}',
    );
    await File(tempPath).writeAsBytes(bytes, flush: true);
    return _UploadResult(
      uploadPath: tempPath,
      fileSize: bytes.length,
      tempPath: tempPath,
    );
  }

  final key = _randomBytes(32);
  final algorithm = AesGcm.with256bits();
  final secretKey = await algorithm.newSecretKeyFromBytes(key);
  final nonce = algorithm.newNonce();
  final secretBox = await algorithm.encrypt(
    bytes,
    secretKey: secretKey,
    nonce: nonce,
  );

  final combined = Uint8List.fromList([
    ...nonce,
    ...secretBox.mac.bytes,
    ...secretBox.cipherText,
  ]);

  final tempPath = p.join(
    payload.tempDirPath,
    'enc_${DateTime.now().microsecondsSinceEpoch}_${_randomHex(8)}',
  );
  await File(tempPath).writeAsBytes(combined, flush: true);

  return _UploadResult(
    uploadPath: tempPath,
    fileSize: combined.length,
    tempPath: tempPath,
    encryptionKeyHex: _bytesToHex(key),
  );
}

Uint8List _randomBytes(int length) {
  final rnd = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => rnd.nextInt(256)));
}

String _randomHex(int length) {
  final rnd = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < length; i++) {
    buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
