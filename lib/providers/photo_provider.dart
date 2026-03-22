import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/photo_collection.dart';

const _collectionsKey = 'photo_collections';

class PhotoProvider extends ChangeNotifier {
  List<PhotoCollection> _collections = [];

  List<PhotoCollection> get collections => List.unmodifiable(_collections);
  List<PhotoCollection> get albumCollections {
    final defaults = _collections.where((c) => c.isDefault).toList(growable: false);
    // 有标记默认的就只用默认集合，否则退回全部 isAlbum 集合
    if (defaults.isNotEmpty) return defaults;
    return _collections.where((c) => c.isAlbum).toList(growable: false);
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_collectionsKey) ?? [];
    try {
      _collections = await compute(
        _parse,
        raw,
      );
    } catch (_) {
      _collections = [];
    }
    notifyListeners();
  }

  static List<PhotoCollection> _parse(List<String> raw) {
    return raw
        .map((e) => PhotoCollection.fromJson(jsonDecode(e) as Map<String, dynamic>))
        .toList();
  }

  Future<void> addCollection(PhotoCollection collection) async {
    final idx = _collections.indexWhere((c) => c.bid == collection.bid);
    if (idx >= 0) {
      final updated = [..._collections];
      updated[idx] = collection;
      _collections = updated;
    } else {
      _collections = [..._collections, collection];
    }
    await _persist();
    notifyListeners();
  }

  Future<void> removeCollection(String bid) async {
    _collections = _collections.where((c) => c.bid != bid).toList();
    await _persist();
    notifyListeners();
  }

  Future<void> toggleAlbum(String bid, bool isAlbum) async {
    _collections = _collections.map((c) => c.bid == bid ? c.copyWith(isAlbum: isAlbum) : c).toList();
    await _persist();
    notifyListeners();
  }

  Future<void> toggleDefault(String bid, bool isDefault) async {
    _collections = _collections.map((c) => c.bid == bid ? c.copyWith(isDefault: isDefault) : c).toList();
    await _persist();
    notifyListeners();
  }

  /// 从网络刷新所有集合的最新数据，有变化才更新
  Future<void> refreshCollections(Future<Map<String, dynamic>> Function(String bid) fetchBlock) async {
    if (_collections.isEmpty) return;
    var changed = false;
    final updated = <PhotoCollection>[];
    for (final col in _collections) {
      try {
        final response = await fetchBlock(col.bid);
        final data = response['data'];
        final blockData = data is Map<String, dynamic> ? data : response;
        if (blockData.isNotEmpty) {
          updated.add(col.copyWith(block: blockData));
          changed = true;
        } else {
          updated.add(col);
        }
      } catch (_) {
        updated.add(col); // 网络失败保留旧数据
      }
    }
    if (changed) {
      _collections = updated;
      await _persist();
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _collectionsKey,
      _collections.map((c) => jsonEncode(c.toJson())).toList(),
    );
  }
}
