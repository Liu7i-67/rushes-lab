/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md 包 F):
/// - F7 审计筛选栏事件类型下拉:英文 raw token 改中文映射(audit_labels 接入,
///   admin_audit_page.dart / audit_filter_bar.dart)。
///
/// 纯组件级用例:AuditFilterBar 受控无状态(筛选值由页面持有),直接挂组件
/// 断言下拉项文案,不依赖 admin 数据面;筛选行为回归由既有 admin_pages_test
/// 全绿兜底(测试功能点 6)。凡依赖「尚未存在的行为」的断言标注
/// TODO(app-polish F7):现状应失败,交付后转绿。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/admin/audit_filter_bar.dart';

void main() {
  testWidgets('F7:审计事件类型下拉暴露中文映射文案,不再裸露英文 raw token',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AuditFilterBar(
          eventType: '',
          projectId: '',
          actor: null,
          day: null,
          projects: const [],
          onEventTypeChanged: (_) {},
          onProjectChanged: (_) {},
          onActorChanged: (_) {},
          onPickDate: () {},
          onClearDate: () {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('— 全部 —'), findsOneWidget, reason: '前置:首位「全部」项在');

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle(); // 下拉菜单展开动画

    // TODO(app-polish F7): 现状应失败(下拉项为 raw token「upload」「download」),
    // 交付后转绿(audit_labels 中文映射接入;具体中文措辞以交付映射为准,
    // 这里钉高频项 upload→上传 / download→下载)
    expect(find.text('上传'), findsOneWidget, reason: 'F7:upload 显示中文');
    expect(find.text('下载'), findsOneWidget, reason: 'F7:download 显示中文');
    expect(find.text('upload'), findsNothing,
        reason: 'F7:不再暴露英文 raw token');
    expect(find.text('download'), findsNothing,
        reason: 'F7:不再暴露英文 raw token');

    // 收尾:点空白关闭菜单,排空路由动画
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });
}
