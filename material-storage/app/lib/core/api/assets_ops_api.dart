/// AssetOpsApi — /api/v1/assets 操作族薄封装(B5 素材操作线;与上传/列表
/// assets_api.dart 分文件守 300 行硬顶)。契约以 api/app/models/__init__.py +
/// routers/assets.py 实码为准;4xx detail 透传由 [MsApi.err] 渲染;**5xx 不经
/// guard5xx**:validateStatus 只放行 <500,5xx 在 dio 层抛 DioException.
/// badResponse 原样上抛,调用方 catch 渲染;全 API 层 5xx 统一兜底=已知技术债,
/// B9 收尾批处理。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class AssetOpsApi {
  AssetOpsApi(this._api);

  final MsApi _api;

  /// 打标/改标 PATCH /assets/{id}/meta:user_labels/notes 缺省=不改;**单条编辑
  /// 不传 labels_mode**(后端默认 replace);批量 merge/replace 由调用方显式传。
  Future<Asset> updateMeta(
    String assetId, {
    List<String>? userLabels,
    String? notes,
    String? labelsMode,
  }) async {
    final data = <String, dynamic>{
      'user_labels': ?userLabels,
      'notes': ?notes,
      'labels_mode': ?labelsMode,
    };
    final r = await _api.http.patch('/api/v1/assets/$assetId/meta', data: data);
    if (r.statusCode != 200) throw _api.err(r, '标签保存失败');
    return Asset.fromJson(r.data as Map<String, dynamic>);
  }

  /// 批量前缀(单批 asset_ids ≤1000;prefix 服务端 NFC 归一+≤128,禁 "/")。
  Future<AssetBatchPrefixResult> batchPrefix(
    List<String> assetIds, {
    required String action, // add | remove
    required String prefix,
  }) async {
    final r = await _api.http.post('/api/v1/assets/batch-prefix', data: {
      'asset_ids': assetIds,
      'action': action,
      'prefix': prefix,
    });
    if (r.statusCode != 200) throw _api.err(r, '批量改名失败');
    return AssetBatchPrefixResult.fromJson(r.data as Map<String, dynamic>);
  }

  /// 批量移动(一期项目内:整批同项目且目标夹同项目,后端 400 兜底)。
  Future<AssetBatchMoveResult> batchMove(
    List<String> assetIds, {
    required String targetFolderId,
  }) async {
    final r = await _api.http.post('/api/v1/assets/batch-move', data: {
      'asset_ids': assetIds,
      'target_folder_id': targetFolderId,
    });
    if (r.statusCode != 200) throw _api.err(r, '批量移动失败');
    return AssetBatchMoveResult.fromJson(r.data as Map<String, dynamic>);
  }

  /// 回收站列表(普通夹需 can_admin 或 my_delete_grant;sensitive 仅系统 admin,
  /// 无权 403 detail 透传)。limit 上限 500。
  Future<TrashPage> listTrash(String folderId,
      {int limit = 500, int offset = 0}) async {
    final r = await _api.http.get('/api/v1/assets/trash', queryParameters: {
      'folder_id': folderId,
      'limit': limit,
      'offset': offset,
    });
    if (r.statusCode != 200) throw _api.err(r, '回收站加载失败');
    return TrashPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// 恢复软删文件(204;不动 MinIO 对象与 OpenFGA tuple)。
  Future<void> restore(String assetId) async {
    final r = await _api.http.post('/api/v1/assets/$assetId/restore');
    if (r.statusCode != 200 && r.statusCode != 204) {
      throw _api.err(r, '恢复失败');
    }
  }
}
