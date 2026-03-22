import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:block_flutter/block_flutter.dart';

import '../models/photo_collection.dart';
import '../providers/connection_provider.dart';

class ImageService {
  ImageService(this._connectionProvider);

  final ConnectionProvider _connectionProvider;

  String? get _endpoint => _connectionProvider.ipfsEndpoint;

  final _pending = HashMap<String, Future<Uint8List>>();

  Future<Uint8List?> loadImage(
    PhotoItem photo, {
    ImageVariant variant = ImageVariant.medium,
  }) async {
    if (photo.cid.isEmpty) return null;
    final endpoint = _endpoint;
    if (endpoint == null || endpoint.isEmpty) return null;

    try {
      // 1. 内存缓存
      final mem = ImageCacheHelper.getMemoryImage(photo.cid, variant: variant);
      if (mem != null) return mem;

      // 2. 磁盘缓存
      final disk = await ImageCacheHelper.getCachedImage(photo.cid, variant: variant);
      if (disk != null) {
        final bytes = await disk.readAsBytes();
        ImageCacheHelper.cacheMemoryImage(photo.cid, bytes, variant: variant);
        return bytes;
      }

      // 3. 网络下载（去重并发）
      final key = '${variant.name}::${photo.cid}';
      final existing = _pending[key];
      if (existing != null) return await existing;

      final future = _downloadAndDecrypt(photo, endpoint);
      _pending[key] = future;
      try {
        final originalBytes = await future;
        // 对 thumb/small/medium 生成缩放版本，original 直接存
        final bytes = variant == ImageVariant.original
            ? originalBytes
            : await ImageCacheHelper.ensureVariant(photo.cid, originalBytes, variant: variant);
        ImageCacheHelper.cacheMemoryImage(photo.cid, bytes, variant: variant);
        unawaited(ImageCacheHelper.saveImageToCache(photo.cid, bytes, variant: variant));
        return bytes;
      } finally {
        _pending.remove(key);
      }
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _downloadAndDecrypt(PhotoItem photo, String endpoint) async {
    final url = '${endpoint.replaceAll(RegExp(r'/+$'), '')}/${photo.cid}';
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }

    var bytes = response.bodyBytes;

    if (photo.isEncrypted) {
      final key = photo.encryptionKey!;
      bytes = await Isolate.run(() => _decryptSync(bytes, key));
    }

    return bytes;
  }
}

/// 在 Isolate 中运行的解密入口（顶层函数）
Future<Uint8List> _decryptSync(Uint8List data, String keyValue) async {
  if (data.length < 32) throw Exception('Encrypted payload too short');

  final keyBytes = _decodeKey(keyValue);
  final algorithm = AesGcm.with256bits();
  final secretKey = await algorithm.newSecretKeyFromBytes(keyBytes);

  final strategies = [
    (nonceLen: 12, macAtEnd: false),
    (nonceLen: 12, macAtEnd: true),
    (nonceLen: 16, macAtEnd: false),
    (nonceLen: 16, macAtEnd: true),
  ];

  for (final s in strategies) {
    if (data.length <= s.nonceLen + 16) continue;
    try {
      final nonce = data.sublist(0, s.nonceLen);
      final Uint8List mac;
      final Uint8List cipher;
      if (s.macAtEnd) {
        mac = data.sublist(data.length - 16);
        cipher = data.sublist(s.nonceLen, data.length - 16);
      } else {
        mac = data.sublist(s.nonceLen, s.nonceLen + 16);
        cipher = data.sublist(s.nonceLen + 16);
      }
      final box = SecretBox(cipher, nonce: nonce, mac: Mac(mac));
      final decrypted = await algorithm.decrypt(box, secretKey: secretKey);
      return Uint8List.fromList(decrypted);
    } on SecretBoxAuthenticationError {
      continue;
    } catch (_) {
      continue;
    }
  }
  throw Exception('Unsupported encrypted payload format');
}

Uint8List _decodeKey(String value) {
  final normalized = value.trim();
  // 尝试 hex
  if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized) && normalized.length.isEven) {
    return _hexToBytes(normalized);
  }
  // 尝试 base64
  try {
    final padded = _padBase64(normalized);
    return base64Decode(padded);
  } catch (_) {}
  return _hexToBytes(normalized);
}

Uint8List _hexToBytes(String hex) {
  final cleaned = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final result = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < cleaned.length; i += 2) {
    result[i ~/ 2] = int.parse(cleaned.substring(i, i + 2), radix: 16);
  }
  return result;
}

String _padBase64(String s) {
  final rem = s.length % 4;
  if (rem == 0) return s;
  return s + '=' * (4 - rem);
}
