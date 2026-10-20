/// Project — /api/v1/projects 契约(现役平移;my_roles/is_archived 等后续批补)。
library;

class Project {
  Project({required this.id, required this.name, required this.code});

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        code: (j['code'] ?? '') as String,
      );

  final String id;
  final String name;
  final String code;
}
