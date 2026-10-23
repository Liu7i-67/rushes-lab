/// app-polish F7 + app-polish-2 I2 验收用例(审计筛选栏,纯组件级):
/// - F7 审计事件类型文案走中文映射(audit_labels 接入),不裸露英文 raw token;
/// - I2(#6)事件类型/项目两处下拉改「只读字段+弹层选择器」:点按弹层 →
///   搜索过滤 → 选择回填回调;回调值恒为 raw token/项目 id(''=全部),
///   数据流不变;取消=维持现状。
///
/// 受控无状态组件直挂断言,不依赖 admin 数据面;筛选行为回归由既有
/// admin_pages_test 全绿兜底。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/admin/admin_home.dart';
import 'package:ms_app/features/admin/audit_filter_bar.dart';
import 'package:ms_app/features/admin/audit_labels.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/app_card.dart';
import 'package:ms_app/widgets/pickers/picker_sheet.dart';

/// 弹层内行(行的 ListTile 为目标:弹层搜索框的 EditableText 在键入词与行
/// 文案相同时也会命中 find.text,须按行组件去重)。
Finder _sheetRow(String label) =>
    find.descendant(of: find.byType(ListTile), matching: find.text(label));

AuditFilterBar _bar({
  String eventType = '',
  String projectId = '',
  List<Project> projects = const [],
  required ValueChanged<String> onEventType,
  required ValueChanged<String> onProject,
}) {
  return AuditFilterBar(
    eventType: eventType,
    projectId: projectId,
    actor: null,
    day: null,
    projects: projects,
    onEventTypeChanged: onEventType,
    onProjectChanged: onProject,
    onActorChanged: (_) {},
    onPickDate: () {},
    onClearDate: () {},
  );
}

void main() {
  testWidgets('F7/I2:事件类型字段点按弹层,中文映射文案可搜可选,回调 raw token', (tester) async {
    String? picked;
    var eventType = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return _bar(
                eventType: eventType,
                onEventType: (v) {
                  picked = v;
                  setState(() => eventType = v); // 受控组件:宿主持值回填
                },
                onProject: (_) {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    // 关闭态字段:「全部」项文案(I1 前的 F7 断言原样保留)
    expect(find.text('— 全部 —'), findsOneWidget);

    await tester.tap(find.byType(PickerField).first);
    await tester.pumpAndSettle();

    // 弹层内中文映射(F7),不裸露 raw token
    expect(_sheetRow('上传'), findsOneWidget, reason: 'F7:upload 显示中文');
    expect(_sheetRow('下载'), findsOneWidget, reason: 'F7:download 显示中文');
    expect(_sheetRow('upload'), findsNothing, reason: 'F7:不再暴露英文 raw token');
    expect(_sheetRow('download'), findsNothing);

    // 搜索过滤(中文 label 可搜,I2;搜索框限定弹层范围——字段本体 TextField
    // 在遮罩后仍在树里)
    await tester.enterText(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
      '上传',
    );
    await tester.pump();
    expect(_sheetRow('下载'), findsNothing);

    await tester.tap(_sheetRow('上传'));
    await tester.pumpAndSettle();
    expect(picked, 'upload', reason: 'I2:选择回填 raw token(数据流不变)');
    // 关闭态字段回填中文
    expect(find.text('上传'), findsOneWidget);
  });

  testWidgets('I2:项目字段弹层列出「全部项目+名(code)」,选择回填项目 id;'
      '已选态中文化', (tester) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _bar(
            eventType: 'upload',
            projectId: 'p1',
            projects: [
              Project(id: 'p1', name: '医美项目', code: 'ym'),
              Project(id: 'p2', name: '婚礼项目', code: 'hl'),
            ],
            onEventType: (_) {},
            onProject: (v) => picked = v,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.text('上传'),
      findsOneWidget,
      reason: '事件类型已选态展示中文(值仍 raw token)',
    );
    expect(find.text('医美项目(ym)'), findsOneWidget, reason: '项目已选态展示名(code)');

    // 打开项目弹层 → 「全部项目」与事件类型「— 全部 —」文案区分(F7)→ 选择
    await tester.tap(find.byType(PickerField).at(1));
    await tester.pumpAndSettle();
    expect(_sheetRow('婚礼项目(hl)'), findsOneWidget, reason: '弹层列出全部项目(名(code))');
    expect(_sheetRow('全部项目'), findsOneWidget, reason: 'null 项(全部)语义保留');
    expect(_sheetRow('— 全部 —'), findsNothing, reason: '项目弹层不混入事件类型的「— 全部 —」文案');
    await tester.tap(_sheetRow('全部项目'));
    await tester.pumpAndSettle();
    expect(picked, '', reason: '「全部项目」= 空串(与原下拉 null→\'\' 语义一致)');
  });

  group('墨金管理后台(WP9 视觉验收)', () {
    tearDown(() => session.me = null);

    testWidgets('管理首页:17 标题 + 副标题,六磁贴 2 列(卡间 10,同列左对齐)', (tester) async {
      session.me = Me.fromJson({
        'id': 'u1',
        'name': '管理员',
        'is_system_admin': true,
      });
      await tester.pumpWidget(const MaterialApp(home: AdminHomePage()));
      await tester.pumpAndSettle();

      expect(find.text('管理后台'), findsOneWidget);
      expect(find.text('系统管理员 · 用户、用户组、审计与模板'), findsOneWidget);
      for (final label in ['用户', '用户组', '审计日志', '授权模板', '目录模板', '备份任务']) {
        expect(find.text(label), findsOneWidget, reason: '磁贴:$label');
      }

      // 2 列:前两枚同 y、第二列在右;第三枚换行
      final r1 = tester.getRect(find.text('用户'));
      final r2 = tester.getRect(find.text('用户组'));
      final r3 = tester.getRect(find.text('审计日志'));
      expect(r1.top, closeTo(r2.top, 0.5), reason: '首行两列');
      expect(r2.left, greaterThan(r1.left), reason: '第二列在右');
      expect(r3.top, greaterThan(r1.top), reason: '第三枚换行');
      expect(r3.left, closeTo(r1.left, 0.5), reason: '左列对齐');
      // 卡间 10 + 最小高 104
      final cards = find.byType(AppCard);
      expect(cards, findsNWidgets(6));
      final c1 = tester.getRect(cards.at(0));
      final c2 = tester.getRect(cards.at(1));
      expect(c2.left - c1.right, closeTo(10, 0.5), reason: '2 列卡间 10');
      expect(c1.height, greaterThanOrEqualTo(104), reason: '磁贴最小高 104');
    });

    testWidgets('管理首页 320 宽 + 字号 1.3:双列不 overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      session.me = Me.fromJson({
        'id': 'u1',
        'name': '管理员',
        'is_system_admin': true,
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: const AdminHomePage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: '320×640 + 1.3 无 overflow',
      );
      expect(find.byType(AppCard), findsNWidgets(6));
    });

    testWidgets('非 admin 深链兜底:PageHeader 返回 + lock 空态', (tester) async {
      session.me = Me.fromJson({
        'id': 'u2',
        'name': '普通成员',
        'is_system_admin': false,
      });
      await tester.pumpWidget(const MaterialApp(home: AdminHomePage()));
      await tester.pumpAndSettle();

      expect(find.text('管理后台'), findsOneWidget);
      expect(find.text('只有系统管理员可以进入管理后台'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('用户'), findsNothing);
    });

    testWidgets('审计分类色随主题令牌:access_denied=danger / upload=gold / '
        '其余=ink2', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      // 裸 MaterialApp 无 TkColors extension → context.tk 按 brightness 兜底
      // (浅色默认主题)
      expect(auditEventColor(ctx, 'access_denied'), TkColors.light.danger);
      expect(auditEventColor(ctx, 'upload'), TkColors.light.gold);
      expect(auditEventColor(ctx, 'baidu_task_create'), TkColors.light.ok);
      expect(auditEventColor(ctx, 'unknown_event'), TkColors.light.ink2);
    });
  });
}
