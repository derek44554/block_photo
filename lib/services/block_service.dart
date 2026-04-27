import 'package:block_flutter/block_flutter.dart';
import '../providers/connection_provider.dart';

const _fileModelId = 'c4238dd0d3d95db7b473adb449f6d282';
const _batchSize = 20;

class BlockService {
  BlockService(this._connectionProvider);

  final ConnectionProvider _connectionProvider;

  ConnectionModel get _connection {
    final c = _connectionProvider.activeConnection;
    if (c == null) throw StateError('No active connection available.');
    return c;
  }

  BlockApi get _api => BlockApi(connection: _connection);

  Future<List<String>> syncCollectionBids({
    required List<String> collectionBids,
    void Function(int fetched, int total)? onProgress,
    String? tag,
  }) async {
    if (collectionBids.isEmpty) return [];

    // 单集合用 /link/main/multiple（支持 tag），多集合用 bids_by_targets
    final List<String> allBids;
    if (collectionBids.length == 1) {
      allBids = await _getBidsByMainWithTag(collectionBids.first, tag: tag);
    } else {
      allBids = await _api.getBidsByTargets(
        bids: collectionBids,
        order: 'desc',
      );
    }

    final missing = <String>[];
    for (final bid in allBids) {
      final cached = await BlockCache.instance.get(bid);
      if (cached == null) missing.add(bid);
    }

    for (var i = 0; i < missing.length; i += _batchSize) {
      final batch = missing.sublist(
        i,
        (i + _batchSize).clamp(0, missing.length),
      );
      try {
        final response = await _api.getMultipleBlocks(bids: batch);
        final data = response['data'] ?? response;
        final blocks = data['blocks'];
        if (blocks is List) {
          for (final item in blocks.whereType<Map<String, dynamic>>()) {
            final block = BlockModel(data: item);
            final bid = block.maybeString('bid');
            if (bid != null) await BlockCache.instance.put(bid, block);
          }
        }
      } catch (_) {}
      onProgress?.call(
        (i + batch.length).clamp(0, missing.length),
        missing.length,
      );
    }

    return allBids;
  }

  Future<List<BlockModel>> getLocalBlocks({
    required List<String> bids,
    required int page,
    required int limit,
  }) async {
    final start = (page - 1) * limit;
    if (start >= bids.length) return [];
    final end = (start + limit).clamp(0, bids.length);
    final pageBids = bids.sublist(start, end);

    final result = <BlockModel>[];
    for (final bid in pageBids) {
      final block = await BlockCache.instance.get(bid);
      if (block != null && _isFileBlock(block)) result.add(block);
    }
    return result;
  }

  bool _isFileBlock(BlockModel block) {
    final model = block.maybeString('model');
    if (model != _fileModelId) return false;
    final ipfs = block.getMap('ipfs');
    return ipfs.isNotEmpty && ipfs['cid'] != null;
  }

  Future<List<BlockModel>> getPhotosByCollections({
    required List<String> collectionBids,
    int page = 1,
    int limit = 40,
  }) async {
    if (collectionBids.isEmpty) return [];
    final response = await _api.getLinksByTargets(
      bids: collectionBids,
      page: page,
      limit: limit,
      order: 'desc',
    );
    return _extractFileBlocks(response);
  }

  Future<BlockModel> getBlock(String bid) async {
    final cached = await BlockCache.instance.get(bid);
    if (cached != null) return cached;
    final response = await _api.getBlock(bid: bid);
    final data = response['data'];
    final blockData = data is Map<String, dynamic> ? data : response;
    final block = BlockModel(data: blockData);
    await BlockCache.instance.put(bid, block);
    return block;
  }

  /// 获取集合 Block 的最新数据（用于刷新集合信息，不走缓存）
  Future<Map<String, dynamic>> fetchCollectionBlock(String bid) async {
    return _api.getBlock(bid: bid);
  }

  Future<BlockModel> fetchBlock(String bid) async {
    final response = await _api.getBlock(bid: bid);
    final data = response['data'];
    final blockData = data is Map<String, dynamic> ? data : response;
    final block = BlockModel(data: blockData);
    await BlockCache.instance.put(bid, block);
    return block;
  }

  Future<void> saveBlock(Map<String, dynamic> data) async {
    await _api.saveBlock(data: data);
  }

  Future<List<String>> getLinkedCollectionBids(String bid) async {
    final response = await _api.getLinksByTarget(bid: bid, limit: 100);
    final data = response['data'];
    if (data is! Map<String, dynamic>) return [];
    final items = data['items'];
    if (items is! List) return [];
    return items
        .whereType<Map<String, dynamic>>()
        .map(
          (e) =>
              (e['main'] ??
                      e['main_bid'] ??
                      e['collection'] ??
                      e['collection_bid'] ??
                      '')
                  as String,
        )
        .where((s) => s.isNotEmpty)
        .toList();
  }

  List<BlockModel> _extractFileBlocks(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is! Map<String, dynamic>) return [];
    final items = data['items'];
    if (items is! List) return [];
    return items
        .whereType<Map<String, dynamic>>()
        .map((e) => BlockModel(data: e))
        .where((block) {
          final model = block.maybeString('model');
          if (model != _fileModelId) return false;
          final ipfs = block.getMap('ipfs');
          return ipfs.isNotEmpty && ipfs['cid'] != null;
        })
        .toList();
  }

  /// tag 视图直接分页请求，不缓存
  Future<List<BlockModel>> getLinksByMainWithTag({
    required String collectionBid,
    required String tag,
    int page = 1,
    int limit = 40,
  }) async {
    final response = await _api.getLinksByMain(
      bid: collectionBid,
      page: page,
      limit: limit,
      tag: tag,
      order: 'desc',
    );
    return _extractFileBlocks(response);
  }

  /// 通过 /link/main/multiple 分页拉取所有 BID（支持 tag 过滤）
  Future<List<String>> _getBidsByMainWithTag(
    String collectionBid, {
    String? tag,
  }) async {
    final result = <String>[];
    int page = 1;
    const limit = 100;
    while (true) {
      final response = await _api.getLinksByMain(
        bid: collectionBid,
        page: page,
        limit: limit,
        tag: tag,
        order: 'desc',
      );
      final data = response['data'];
      if (data is! Map<String, dynamic>) break;
      final items = data['items'];
      if (items is! List || items.isEmpty) break;
      for (final item in items.whereType<Map<String, dynamic>>()) {
        final block = BlockModel(data: item);
        final bid = block.maybeString('bid');
        if (bid != null) {
          await BlockCache.instance.put(bid, block);
          result.add(bid);
        }
      }
      if (items.length < limit) break;
      page++;
    }
    return result;
  }
}
