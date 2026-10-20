/// 测试功能点 3(B2):ROLE_META 徽标映射 — 四角色主 chip、多角色 +N、
/// 仅访客、未知角色兜底(同 web ProjectsPage.MyRolesBadge 口径)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/projects/role_badge.dart';
import 'package:ms_app/widgets/badge.dart';

void main() {
  test('四角色主 chip:admin→管理/accent、uploader→上传/amber、'
      'downloader→下载/green、viewer→查看/neutral', () {
    expect(roleChipSpec(['admin']),
        isA<RoleChipSpec>()
            .having((s) => s.label, 'label', '管理')
            .having((s) => s.tone, 'tone', BadgeTone.accent)
            .having((s) => s.extraCount, 'extra', 0));
    expect(roleChipSpec(['uploader']).label, '上传');
    expect(roleChipSpec(['uploader']).tone, BadgeTone.amber);
    expect(roleChipSpec(['downloader']).label, '下载');
    expect(roleChipSpec(['downloader']).tone, BadgeTone.green);
    expect(roleChipSpec(['viewer']).label, '查看');
    expect(roleChipSpec(['viewer']).tone, BadgeTone.neutral);
  });

  test('ROLE_RANK 取最高:admin > uploader > downloader > viewer', () {
    final s = roleChipSpec(['viewer', 'uploader', 'admin']);
    expect(s.label, '管理');
    expect(s.extraCount, 2); // 其余两角色 +N
    expect(roleChipSpec(['downloader', 'viewer']).label, '下载');
  });

  test('空角色 → 「仅访客」(visibility=public 可见口径)', () {
    final s = roleChipSpec([]);
    expect(s.guest, isTrue);
    expect(s.label, '仅访客');
    expect(s.tone, BadgeTone.neutral);
    expect(s.extraCount, 0);
  });

  test('未知角色值按 viewer 兜底(web ROLE_META[top] || viewer)', () {
    final s = roleChipSpec(['superuser']);
    expect(s.label, '查看');
    expect(s.tone, BadgeTone.neutral);
  });

  test('ROLE_META/ROLE_RANK 与 web 同色同序(契约锚点)', () {
    expect(kRoleMeta['admin']!.$1, '管理');
    expect(kRoleMeta['uploader']!.$1, '上传');
    expect(kRoleMeta['downloader']!.$1, '下载');
    expect(kRoleMeta['viewer']!.$1, '查看');
    expect(kRoleRank, ['admin', 'uploader', 'downloader', 'viewer']);
  });
}
