/// PrefsApi — /api/v1/me/preferences 薄封装(2026-11-19 settings-mcp-collapse
/// §6 App 侧固定契约,app-B 设置页/文件夹页按此调用):GET 读全集,
/// PUT 部分更新(仅传的键覆盖,其余保持原值)并回合并后全集。
/// session 鉴权与 /auth/me 同源;非 200 → `_api.err` 中文报错(401 走既有
/// 跳登录语义,由 MsApi 统一钩子处置)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class PrefsApi {
  PrefsApi(this._api);

  final MsApi _api;

  /// 读偏好全集(无偏好行用户后端补默认值,恒 200 全字段)。
  Future<UserPrefs> getPrefs() async {
    final r = await _api.http.get('/api/v1/me/preferences');
    if (r.statusCode != 200) throw _api.err(r, '偏好设置加载失败');
    return UserPrefs.fromJson(r.data as Map<String, dynamic>);
  }

  /// 部分更新:仅传 [folderTreeDefaultCollapsed] 时只覆盖该键,回合并后全集。
  Future<UserPrefs> updatePrefs({bool? folderTreeDefaultCollapsed}) async {
    final r = await _api.http.put(
      '/api/v1/me/preferences',
      data: {
        'folder_tree_default_collapsed': ?folderTreeDefaultCollapsed,
      },
    );
    if (r.statusCode != 200) throw _api.err(r, '偏好保存失败');
    return UserPrefs.fromJson(r.data as Map<String, dynamic>);
  }
}
