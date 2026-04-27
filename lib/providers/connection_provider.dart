import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:block_flutter/block_flutter.dart';

class ConnectionProvider extends ChangeNotifier {
  static const _storageKey = 'block_connections';
  static const _activeKey = 'block_active_index';
  static const _ipfsKey = 'block_ipfs_endpoint';

  List<ConnectionModel> _connections = [];
  ConnectionModel? _activeConnection;
  String? _ipfsEndpoint;

  List<ConnectionModel> get connections => List.unmodifiable(_connections);
  ConnectionModel? get activeConnection => _activeConnection;
  bool get hasActiveConnection => _activeConnection != null;
  String? get ipfsEndpoint => _ipfsEndpoint;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? [];
    _connections = [];
    for (final item in raw) {
      try {
        final decoded = jsonDecode(item);
        if (decoded is Map<String, dynamic>) {
          _connections.add(ConnectionModel.fromJson(decoded));
        }
      } catch (_) {
        // 忽略损坏的单条连接配置，保留其他可用配置。
      }
    }

    final activeIndex = prefs.getInt(_activeKey) ?? 0;
    if (_connections.isNotEmpty) {
      _activeConnection =
          _connections[activeIndex.clamp(0, _connections.length - 1)];
    }
    _ipfsEndpoint = prefs.getString(_ipfsKey);
    notifyListeners();

    // 启动时自动刷新所有连接的 nodeData
    for (final c in List.unmodifiable(_connections)) {
      _refreshNodeData(c);
    }
  }

  /// 后台刷新连接的 nodeData（获取节点 sender BID 等信息）
  Future<void> _refreshNodeData(ConnectionModel connection) async {
    try {
      final nodeData = await ApiClient(
        connection: connection,
      ).postToBridge(protocol: 'open', routing: '/node/node', data: const {});
      final index = _connections.indexWhere(
        (c) => c.address == connection.address,
      );
      if (index == -1) return;
      _connections[index] = _connections[index].copyWith(nodeData: nodeData);
      if (_activeConnection?.address == connection.address) {
        _activeConnection = _connections[index];
      }
      await _persist();
      notifyListeners();
    } catch (_) {
      // 网络不可用时静默失败
    }
  }

  Future<void> addConnection(ConnectionModel connection) async {
    final existingIndex = _connections.indexWhere(
      (c) => c.address == connection.address,
    );
    if (existingIndex >= 0) {
      _connections[existingIndex] = connection;
      if (_activeConnection?.address == connection.address) {
        _activeConnection = connection;
      }
    } else {
      _connections.add(connection);
    }

    if (_activeConnection == null) {
      final activeIndex = existingIndex >= 0
          ? existingIndex
          : _connections.length - 1;
      _activeConnection = _connections[activeIndex];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_activeKey, activeIndex);
    }
    await _persist();
    notifyListeners();
    // 如果 nodeData 为空，后台刷新
    if (connection.nodeData == null) {
      _refreshNodeData(connection);
    }
  }

  Future<void> removeConnection(int index) async {
    if (index < 0 || index >= _connections.length) return;
    _connections.removeAt(index);
    final prefs = await SharedPreferences.getInstance();
    final currentActiveIndex = _resolveActiveIndex(
      fallback: prefs.getInt(_activeKey) ?? 0,
      removedIndex: index,
    );

    if (_connections.isEmpty) {
      _activeConnection = null;
      await prefs.setInt(_activeKey, 0);
    } else {
      final nextActiveIndex = currentActiveIndex.clamp(
        0,
        _connections.length - 1,
      );
      _activeConnection = _connections[nextActiveIndex];
      await prefs.setInt(_activeKey, nextActiveIndex);
    }
    await _persist();
    notifyListeners();
  }

  int _resolveActiveIndex({required int fallback, required int removedIndex}) {
    final active = _activeConnection;
    final beforeRemoveLength = _connections.length + 1;
    var activeIndex = active == null
        ? fallback
        : _connections.indexWhere(
            (c) =>
                c.address == active.address && c.keyBase64 == active.keyBase64,
          );

    if (activeIndex == -1) {
      activeIndex = fallback.clamp(0, beforeRemoveLength - 1);
    } else if (activeIndex >= removedIndex) {
      // index 已经在删除后的列表中；换算回删除前的位置再统一处理。
      activeIndex += 1;
    }

    if (activeIndex == removedIndex) {
      return removedIndex;
    }
    if (activeIndex > removedIndex) {
      return activeIndex - 1;
    }
    return activeIndex;
  }

  Future<void> setActive(int index) async {
    if (index < 0 || index >= _connections.length) return;
    _activeConnection = _connections[index];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_activeKey, index);
    notifyListeners();
  }

  Future<void> setIpfsEndpoint(String? endpoint) async {
    _ipfsEndpoint = endpoint?.trim().isEmpty == true ? null : endpoint?.trim();
    final prefs = await SharedPreferences.getInstance();
    if (_ipfsEndpoint != null) {
      await prefs.setString(_ipfsKey, _ipfsEndpoint!);
    } else {
      await prefs.remove(_ipfsKey);
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _storageKey,
      _connections.map((c) => jsonEncode(c.toJson())).toList(),
    );
  }
}
