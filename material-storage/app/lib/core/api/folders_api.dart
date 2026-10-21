/// FoldersApi — /api/v1/folders 族薄封装(B2 补单夹详情;授权/增删改后续批)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class FoldersApi {
  FoldersApi(this._api);

  final MsApi _api;

  /// 项目内文件夹 flat 列表(前端内存建树;subtree_file_count 仅此端点回填)。
  Future<List<Folder>> list(String projectId) async {
    final r = await _api.http.get('/api/v1/folders',
        queryParameters: {'project_id': projectId});
    if (r.statusCode != 200) throw _api.err(r, '目录列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => Folder.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 单夹详情 — my_can_view/download/upload/admin 的唯一可信回填点
  /// (web useFolder 同源;列表响应恒 False 勿消费,方案 §11 钉子)。
  Future<Folder> get(String folderId) async {
    final r = await _api.http.get('/api/v1/folders/$folderId');
    if (r.statusCode != 200) throw _api.err(r, '文件夹详情加载失败');
    return Folder.fromJson(r.data as Map<String, dynamic>);
  }
}
