/// McpTokensPage 验收(settings-mcp P2 批,P2-2 列表失败静默滞留修复):
/// - 首次拉取成功落列表后,再次刷新失败(切换 include_revoked 重拉与下拉
///   刷新同路 _reload)→ 旧列表保留 + 列表顶部行内错误条可见
///   (「刷新失败,当前为缓存数据」+「点击重试」);点击重试成功后错误条
///   消失、列表换新;
/// - 首载失败(无缓存数据)仍走整页 ErrorView,不出行内错误条(两路径互斥)。
///
/// 打桩:helpers/api_harness 的 FakeTokensApi(session.api!.tokens 域覆写,
/// listStaged 队列逐次编排),编排须在 pumpWidget(首个请求)前就位。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/settings/mcp_tokens_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/error_view.dart';

import '../helpers/api_harness.dart';

/// 列表行样本(expired 在场=false,后端派生列口径)。
PatToken tokenOf(String id, String name) => PatToken.fromJson(<String, dynamic>{
      'id': id,
      'name': name,
      'token_prefix': 'mspat_$id',
      'created_at': '2026-11-19T08:00:00Z',
      'expires_at': '2099-02-17T08:00:00Z',
      'expired': false,
    });

/// 装配 tokens 假域(先编排后 pump 的两段式:本 helper 只注入,不挂页面)。
FakeTokensApi _installTokens() {
  final api = installFakeApi();
  addTearDown(() => session.api = null);
  return api.tokens;
}

void main() {
  testWidgets('P2-2:首载成功后重拉失败 → 旧列表保留+行内错误条;重试成功恢复',
      (tester) async {
    final tokens = _installTokens()..listResult = [tokenOf('t1', 'CI 令牌')];
    await tester.pumpWidget(const MaterialApp(home: McpTokensPage()));
    await tester.pumpAndSettle();

    expect(tokens.listCalls, [false], reason: '首载默认只拉活跃行');
    expect(find.text('CI 令牌'), findsOneWidget);
    expect(find.textContaining('刷新失败'), findsNothing, reason: '首载成功无错误条');

    // 二次重拉失败(切换「显示已吊销 / 已过期」触发同路 _reload)
    tokens.listStaged.add(ApiException(500, '网络断开'));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(tokens.listCalls, [false, true], reason: 'include_revoked=true 重拉');
    expect(
      find.text('CI 令牌'),
      findsOneWidget,
      reason: '失败时旧列表保留(不再静默滞留也不整页报错)',
    );
    expect(
      find.textContaining('刷新失败,当前为缓存数据'),
      findsOneWidget,
      reason: '列表顶部行内错误条可见',
    );
    expect(find.text('点击重试'), findsOneWidget);

    // 点击重试:编排成功且换含历史的新数据 → 错误条消失、列表更新
    tokens.listStaged.add([tokenOf('t1', 'CI 令牌'), tokenOf('t2', '旧令牌')]);
    await tester.tap(find.text('点击重试'));
    await tester.pumpAndSettle();

    expect(tokens.listCalls, [false, true, true], reason: '重试沿用当前查询口径');
    expect(find.text('CI 令牌'), findsOneWidget);
    expect(find.text('旧令牌'), findsOneWidget, reason: '重试成功落新列表');
    expect(find.textContaining('刷新失败'), findsNothing, reason: '成功后错误条消失');
  });

  testWidgets('首载失败(无缓存)仍走整页 ErrorView,不出行内错误条',
      (tester) async {
    final tokens = _installTokens();
    tokens.listStaged.add(ApiException(500, '首载失败'));
    await tester.pumpWidget(const MaterialApp(home: McpTokensPage()));
    await tester.pumpAndSettle();

    expect(
      find.byType(ErrorView),
      findsOneWidget,
      reason: '首载失败整页报错(原行为不变)',
    );
    expect(find.textContaining('首载失败'), findsOneWidget);
    expect(
      find.textContaining('刷新失败,当前为缓存数据'),
      findsNothing,
      reason: '无缓存数据时不存在行内错误条形态',
    );
  });
}
