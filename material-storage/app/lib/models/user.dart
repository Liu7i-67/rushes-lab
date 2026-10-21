/// UserBrief / GroupBrief — 选人组件数据源(B6 §9 pickers;users.py / groups.py
/// 简表契约,web UserPicker / GroupPicker 同源):users 简表 admin 或 project
/// creator 可读(方案 §2.3 弱门);groups 同门。
library;

class UserBrief {
  UserBrief({
    required this.id,
    this.username,
    required this.name,
    this.email,
  });

  factory UserBrief.fromJson(Map<String, dynamic> j) => UserBrief(
        id: j['id'] as String,
        username: j['username'] as String?,
        name: (j['name'] ?? '') as String,
        email: j['email'] as String?,
      );

  /// users.id UUID(#150 起 UserPicker value 语义,勿用飞书 open_id)。
  final String id;
  final String? username;
  final String name;
  final String? email;
}

class GroupBrief {
  GroupBrief({
    required this.id,
    required this.name,
    this.description,
    this.memberCount,
  });

  factory GroupBrief.fromJson(Map<String, dynamic> j) => GroupBrief(
        id: j['id'] as String,
        name: (j['name'] ?? '') as String,
        description: j['description'] as String?,
        memberCount: j['member_count'] as int?,
      );

  /// groups.id UUID(授权主体 `group:<id>#member` 的 id 段)。
  final String id;
  final String name;
  final String? description;

  /// 成员数(groups LEFT JOIN group_memberships 计数)。
  final int? memberCount;
}
