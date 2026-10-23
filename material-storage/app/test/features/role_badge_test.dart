/// 测试功能点 3(B2):ROLE_META 徽标映射 — 四角色主 chip、多角色 +N、
/// 仅访客、未知角色兜底;2026-10 墨金:admin=gold/uploader=warn/
/// downloader=ok/viewer=neutral,渲染色取自 TkColors。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/projects/role_badge.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/badge.dart';

void main() {
  test('四角色主 chip:admin→管理/gold、uploader→上传/warn、'
      'downloader→下载/ok、viewer→查看/neutral', () {
    expect(
      roleChipSpec(['admin']),
      isA<RoleChipSpec>()
          .having((s) => s.label, 'label', '管理')
          .having((s) => s.tone, 'tone', BadgeTone.gold)
          .having((s) => s.extraCount, 'extra', 0),
    );
    expect(roleChipSpec(['uploader']).label, '上传');
    expect(roleChipSpec(['uploader']).tone, BadgeTone.warn);
    expect(roleChipSpec(['downloader']).label, '下载');
    expect(roleChipSpec(['downloader']).tone, BadgeTone.ok);
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

  testWidgets('角色徽标渲染色:admin=金、uploader=warn、downloader=ok', (tester) async {
    Future<Color?> textColor(String role, String label) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: MyRolesBadge(roles: [role])),
          ),
        ),
      );
      await tester.pump();
      final text = tester.widget<Text>(find.text(label));
      return text.style?.color;
    }

    final tk = TkColors.light; // 裸 MaterialApp 默认浅色,context.tk 静态兜底
    expect(await textColor('admin', '管理'), tk.goldInk);
    expect(await textColor('uploader', '上传'), tk.warn);
    expect(await textColor('downloader', '下载'), tk.ok);
    expect(await textColor('viewer', '查看'), tk.ink2);

    // 金浅底容器(admin)
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: MyRolesBadge(roles: ['admin'])),
        ),
      ),
    );
    final box = tester.widget<Container>(
      find
          .ancestor(of: find.text('管理'), matching: find.byType(Container))
          .first,
    );
    expect((box.decoration as BoxDecoration?)?.color, tk.goldSoft);
  });
}
