/// ProjectsApi — /api/v1/projects 族薄封装(现役平移;新建/回收站后续批补)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class ProjectsApi {
  ProjectsApi(this._api);

  final MsApi _api;

  /// 项目列表(默认 limit=100,单页)。
  Future<List<Project>> list() async {
    final r = await _api.http.get('/api/v1/projects');
    if (r.statusCode != 200) throw _api.err(r, '项目列表加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
