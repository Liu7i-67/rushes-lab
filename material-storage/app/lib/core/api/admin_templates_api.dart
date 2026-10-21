/// AdminTemplatesApi — 管理端模板读端点薄封装(B6 新建项目表单预填用):
/// GET /admin/grant-templates(读弱门 = system admin 或 project creator,方案
/// §2.3)与 GET /admin/folder-templates(组合弱门,§3.3)。写端点本批不接
/// (App 随 §8.9 管理后台批做)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class AdminTemplatesApi {
  AdminTemplatesApi(this._api);

  final MsApi _api;

  /// 权限模板列表(含 items + 主体名;403 = 无 project_creator 能力,调用方
  /// 已按闸门显隐,失败静默降级为只有「不使用模板」,web 同口径)。
  Future<List<GrantTemplate>> grantTemplates() async {
    final r = await _api.http.get('/api/v1/admin/grant-templates');
    if (r.statusCode != 200) throw _api.err(r, '权限模板加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => GrantTemplate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 目录模板列表(按 name 排序,带全量 entries 供预览;失败静默降级同上)。
  Future<List<FolderTemplate>> folderTemplates() async {
    final r = await _api.http.get('/api/v1/admin/folder-templates');
    if (r.statusCode != 200) throw _api.err(r, '目录模板加载失败');
    return ((r.data as List? ?? const []))
        .map((e) => FolderTemplate.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
