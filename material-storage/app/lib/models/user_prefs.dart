/// UserPrefs — /api/v1/me/preferences 契约(2026-11-19 settings-mcp-collapse
/// §6 App 侧固定签名;后端 routers/user_preferences.py PreferencesOut 实码)。
/// GET/PUT 均回全集字段,后续新增偏好键在此补字段即可(缺省回落默认值)。
library;

class UserPrefs {
  const UserPrefs({this.folderTreeDefaultCollapsed = false});

  factory UserPrefs.fromJson(Map<String, dynamic> j) => UserPrefs(
        folderTreeDefaultCollapsed:
            (j['folder_tree_default_collapsed'] ?? false) as bool,
      );

  /// 【默认收拢全部文件夹】(F9):开启 = 项目文件夹页进入时默认全部收拢,
  /// 点箭头逐层展开;关闭 = 现状默认全展开。缺省 false(与后端 DEFAULT 一致)。
  final bool folderTreeDefaultCollapsed;
}
