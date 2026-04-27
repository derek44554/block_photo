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

  final _downloadPending = HashMap<String, Future<Uint8List>>();
  final _variantPending = HashMap<String, Future<Uint8List>>();

  Future<Uint8List?> loadImage(
    PhotoItem photo, {
    ImageVariant variant = ImageVariant.medium,
  }) async {
    if (photo.cid.isEmpty) return null;
    final endpoint = _endpoint;
    if (endpoint == null || endpoint.isEmpty) return null;

    try {
      final cached = await _readCachedVariant(photo.cid, variant);
      if (cached != null) return cached;

      final key = '${variant.name}::${photo.cid}';
      final existing = _variantPending[key];
      if (existing != null) return await existing;

      final future = _loadVariant(photo, endpoint, variant);
      _variantPending[key] = future;
      try {
        return await future;
      } finally {
        _variantPending.remove(key);
      }
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _readCachedVariant(
    String cid,
    ImageVariant variant,
  ) async {
    final mem = ImageCacheHelper.getMemoryImage(cid, variant: variant);
    if (mem != null) return mem;

    final disk = await ImageCacheHelper.getCachedImage(cid, variant: variant);
    if (disk == null) return null;

    final bytes = await disk.readAsBytes();
    ImageCacheHelper.cacheMemoryImage(cid, bytes, variant: variant);
    return bytes;
  }

  Future<Uint8List> _loadVariant(
    PhotoItem photo,
    String endpoint,
    ImageVariant variant,
  ) async {
    final originalBytes = await _getOriginalBytes(photo, endpoint);
    final bytes = variant == ImageVariant.original
        ? originalBytes
        : await ImageCacheHelper.ensureVariant(
            photo.cid,
            originalBytes,
            variant: variant,
          );

    ImageCacheHelper.cacheMemoryImage(photo.cid, bytes, variant: variant);
    unawaited(
      ImageCacheHelper.saveImageToCache(photo.cid, bytes, variant: variant),
    );
    return bytes;
  }

  Future<Uint8List> _getOriginalBytes(PhotoItem photo, String endpoint) async {
    final cached = await _readCachedVariant(photo.cid, ImageVariant.original);
    if (cached != null) return cached;

    final existing = _downloadPending[photo.cid];
    if (existing != null) return await existing;

    final future = _downloadAndDecrypt(photo, endpoint);
    _downloadPending[photo.cid] = future;
    try {
      final bytes = await future;
      unawaited(
        ImageCacheHelper.saveImageToCache(
          photo.cid,
          bytes,
          variant: ImageVariant.original,
        ),
      );
      return bytes;
    } finally {
      _downloadPending.remove(photo.cid);
    }
  }

  Future<Uint8List> _downloadAndDecrypt(
    PhotoItem photo,
    String endpoint,
  ) async {
    final url = '${endpoint.replaceAll(RegExp(r'/+$'), '')}/${photo.cid}';
    final response = await http
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 20));
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
  if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(normalized) &&
      normalized.length.isEven) {
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
