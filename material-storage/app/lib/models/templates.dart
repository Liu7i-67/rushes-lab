/// 模板出参契约(B6 新建项目;admin.py GrantTemplateOut / FolderTemplateOut 实码)。
/// 权限模板无「模板 id」建项目入参——前端把 items 展开为 initial_grants 行提交;
/// 目录模板选中有 folder_template_id 直传。
library;

/// 权限模板条目(主体名已由后端解析;主体已删标 missing=true,提交会被
/// 建项目存在性校验 400 拦下,行上要显式提示)。
class GrantTemplateItem {
  GrantTemplateItem({
    required this.kind,
    required this.id,
    required this.roles,
    required this.name,
    required this.missing,
  });

  factory GrantTemplateItem.fromJson(Map<String, dynamic> j) =>
      GrantTemplateItem(
        kind: j['kind'] as String,
        id: j['id'] as String,
        roles: ((j['roles'] ?? const []) as List).map((e) => e as String).toList(),
        name: (j['name'] ?? '') as String,
        missing: (j['missing'] ?? false) as bool,
      );

  final String kind; // user / group
  final String id; // users.id / groups.id UUID
  final List<String> roles; // PROJECT_ROLES 子集
  final String name;
  final bool missing;
}

class GrantTemplate {
  GrantTemplate({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.items,
    this.description,
  });

  factory GrantTemplate.fromJson(Map<String, dynamic> j) => GrantTemplate(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        description: j['description'] as String?,
        isDefault: (j['is_default'] ?? false) as bool,
        items: ((j['items'] ?? const []) as List)
            .map((e) => GrantTemplateItem.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  final String id;
  final String name;
  final String? description;
  final bool isDefault;
  final List<GrantTemplateItem> items;
}

class FolderTemplateEntry {
  FolderTemplateEntry({required this.path});

  factory FolderTemplateEntry.fromJson(Map<String, dynamic> j) =>
      FolderTemplateEntry(path: j['path'] as String);

  final String path;
}

/// 目录模板(带全量 entries 供预览;选中后建项目传 folder_template_id,
/// 目录树由后端创建流程自动建立)。
class FolderTemplate {
  FolderTemplate({
    required this.id,
    required this.name,
    required this.entryCount,
    required this.entries,
    this.description,
  });

  factory FolderTemplate.fromJson(Map<String, dynamic> j) => FolderTemplate(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        description: j['description'] as String?,
        entryCount: (j['entry_count'] ?? 0) as int,
        entries: ((j['entries'] ?? const []) as List)
            .map((e) => FolderTemplateEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  final String id;
  final String name;
  final String? description;
  final int entryCount;
  final List<FolderTemplateEntry> entries;
}
