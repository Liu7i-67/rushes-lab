/// AdminTemplatesApi — 管理端模板端点薄封装(B6 读预填 + B8 写全族):
/// GET/POST/PATCH/DELETE /admin/grant-templates(读弱门 system admin 或
/// project creator,方案 §2.3;写 require_system_admin)、GET /admin/folder-templates
/// (组合弱门 §3.3)与 POST /grant-templates/apply-default(存量项目批量刷新
/// 默认授权,require_system_admin;契约=admin.py ApplyDefaultIn/Out 实码)。
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

  // ── B8:权限模板写端点 ─────────────────────────────────────────────────────

  List<Map<String, dynamic>> _itemsJson(List<GrantEntry> items) => [
        for (final it in items)
          {'kind': it.kind, 'id': it.id, 'roles': it.roles},
      ];

  /// POST /grant-templates — 建模板(items 1..50;409 重名/400 主体不存在透传)。
  Future<GrantTemplate> createTemplate({
    required String name,
    String? description,
    bool isDefault = false,
    required List<GrantEntry> items,
  }) async {
    final r = await _api.http.post('/api/v1/admin/grant-templates', data: {
      'name': name,
      'description': description,
      'is_default': isDefault,
      'items': _itemsJson(items),
    });
    if (r.statusCode != 201) throw _api.err(r, '创建权限模板失败');
    return GrantTemplate.fromJson(r.data as Map<String, dynamic>);
  }

  /// PATCH /grant-templates/{id} — 编辑(items 传了即全量替换;is_default 不传
  /// = 不改;description 恒携带,显式 null=清空——本调用恒传字符串或 null)。
  Future<GrantTemplate> updateTemplate(
    String templateId, {
    String? name,
    String? description,
    bool? isDefault,
    List<GrantEntry>? items,
  }) async {
    final r = await _api.http.patch(
        '/api/v1/admin/grant-templates/$templateId',
        data: {
          'name': ?name,
          'description': description,
          'is_default': ?isDefault,
          'items': ?(items == null ? null : _itemsJson(items)),
        });
    if (r.statusCode != 200) throw _api.err(r, '保存权限模板失败');
    return GrantTemplate.fromJson(r.data as Map<String, dynamic>);
  }

  /// DELETE /grant-templates/{id} — 删模板(items 级联删;204)。
  Future<void> deleteTemplate(String templateId) async {
    final r =
        await _api.http.delete('/api/v1/admin/grant-templates/$templateId');
    if (r.statusCode != 204) throw _api.err(r, '删除权限模板失败');
  }

  /// POST /grant-templates/apply-default — 存量项目补默认模板授权
  /// (叠加不删;project_ids 1..100;部分成功=results 逐项目)。
  Future<ApplyDefaultResult> applyDefault(List<String> projectIds) async {
    final r = await _api.http.post(
        '/api/v1/admin/grant-templates/apply-default',
        data: {'project_ids': projectIds});
    if (r.statusCode != 200) throw _api.err(r, '刷新默认权限失败');
    return ApplyDefaultResult.fromJson(r.data as Map<String, dynamic>);
  }

  // ── B8:目录模板写端点 ─────────────────────────────────────────────────────

  /// POST /folder-templates — 建模板(entries 1..200,路径校验 422/409 重名透传)。
  Future<FolderTemplate> createFolderTemplate(
    String name, {
    String? description,
    required List<String> paths,
  }) async {
    final r = await _api.http.post('/api/v1/admin/folder-templates', data: {
      'name': name,
      'description': description,
      'entries': [for (final p in paths) {'path': p}],
    });
    if (r.statusCode != 201) throw _api.err(r, '创建目录模板失败');
    return FolderTemplate.fromJson(r.data as Map<String, dynamic>);
  }

  /// PATCH /folder-templates/{id} — 编辑(entries 传了即全量替换)。
  Future<FolderTemplate> updateFolderTemplate(
    String templateId, {
    String? name,
    String? description,
    List<String>? paths,
  }) async {
    final r = await _api.http.patch(
        '/api/v1/admin/folder-templates/$templateId',
        data: {
          'name': ?name,
          'description': description,
          'entries': ?(paths == null
              ? null
              : [for (final p in paths) {'path': p}]),
        });
    if (r.statusCode != 200) throw _api.err(r, '保存目录模板失败');
    return FolderTemplate.fromJson(r.data as Map<String, dynamic>);
  }

  /// DELETE /folder-templates/{id} — 删模板(204;应用即快照,不影响已建项目)。
  Future<void> deleteFolderTemplate(String templateId) async {
    final r =
        await _api.http.delete('/api/v1/admin/folder-templates/$templateId');
    if (r.statusCode != 204) throw _api.err(r, '删除目录模板失败');
  }
}
