/// FoldersApi — /api/v1/folders 族薄封装(现役平移;单夹详情/授权等后续批补)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class FoldersApi {
  FoldersApi(this._api);

  final MsApi _api;

  /// 项目内文件夹 flat 列表(前端内存建树)。
  Future<List<Folder>> list(String projectId) async {
    final r = await _api.http.get('/api/v1/folders',
        queryParameters: {'project_id': projectId});
    if (r.statusCode != 200) throw _api.err(r, '目录列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => Folder.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
