/// Project — /api/v1/projects 契约(B2 补 my_roles;素材计数后端无此字段)。
library;

class Project {
  Project({
    required this.id,
    required this.name,
    required this.code,
    this.myRoles = const [],
  });

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        code: (j['code'] ?? '') as String,
        myRoles: ((j['my_roles'] ?? const []) as List)
            .map((e) => e as String)
            .toList(),
      );

  final String id;
  final String name;
  final String code;

  /// 当前 user 在本项目的有效角色('admin'|'uploader'|'downloader'|'viewer');
  /// 空 = 仅靠 visibility=public 可见(「仅访客」)。
  final List<String> myRoles;
}
