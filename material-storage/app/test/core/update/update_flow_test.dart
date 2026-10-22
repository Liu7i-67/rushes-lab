/// 测试功能点 T4/T5/T6:AppUpdateFlow 自动检查编排 —
/// - T4 逻辑层(F2-4):isAndroid=false 直接短路,不 fetch、不消费闸门;
/// - T5 自动检查静默(F2-4):fetchLatest 抛 UpdateException / FormatException /
///   返回旧版本,autoCheckOnce 均不抛、不弹(autoPromptUsed 保持 false),
///   失败不烧 session 闸门;
/// - T6 取消语义(D5):弹窗弹出即消费闸门 —— 无导航器时静默放弃但闸门已用;
///   挂真实 navigatorKey 弹确认框后点「取消」,本 session 不再自动弹(不 fetch 不弹)。
/// service/localVersion 全注入,不触网、不触 PackageInfo;delay 置零。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/update/app_version_info.dart';
import 'package:ms_app/core/update/update_errors.dart';
import 'package:ms_app/core/update/update_flow.dart';
import 'package:ms_app/core/update/update_service.dart';

AppVersionInfo _info({String version = '9.9.9', int build = 1}) =>
    AppVersionInfo(
      version: version,
      build: build,
      changelog: '新版说明',
      force: false,
      androidUrl: 'https://cdn/huanhuashijie-$version.apk',
    );

Future<LocalAppVersion> _localV1() async => (version: '1.0.0', build: 4);

/// fake service:fetchLatest 行为可编排(返回 info 或抛预建异常)+ 调用计数
/// (T6 断言闸门消费后第二次 autoCheckOnce 连 fetch 都不发生)。
class _FakeService extends UpdateService {
  _FakeService(Future<AppVersionInfo> Function() behavior)
      : _behavior = behavior,
        super(
          dio: Dio(),
          versionJsonUrl: 'http://update.test/app_version.json',
        );

  final Future<AppVersionInfo> Function() _behavior;
  int fetchCount = 0;

  @override
  Future<AppVersionInfo> fetchLatest() async {
    fetchCount++;
    return _behavior();
  }
}

void main() {
  group('T4 自动检查平台 gate(逻辑层)', () {
    test('isAndroid=false 直接短路:不 fetch、不消费闸门、不弹', () async {
      final svc = _FakeService(() async => _info());
      final flow = AppUpdateFlow(service: svc, localVersion: _localV1);

      await flow.autoCheckOnce(isAndroid: false, delay: Duration.zero);

      expect(svc.fetchCount, 0, reason: 'iOS/web 连 fetch 都不发生(D6)');
      expect(flow.autoPromptUsed, isFalse);
    });
  });

  group('T5 自动检查静默(F2-4:任何失败完全静默)', () {
    test('fetchLatest 抛 UpdateException(如 404/超时)→ 不抛、不弹、闸门未消费',
        () async {
      final svc = _FakeService(
          () async => throw const UpdateException('服务异常(HTTP 404)'));
      final flow = AppUpdateFlow(service: svc, localVersion: _localV1);

      await expectLater(
        flow.autoCheckOnce(isAndroid: true, delay: Duration.zero),
        completes,
        reason: '自动检查整体吞异常(T5 无 toast 无弹窗无日志)',
      );
      expect(flow.autoPromptUsed, isFalse);
      expect(svc.fetchCount, 1);
    });

    test('fetchLatest 抛 FormatException(坏 JSON/字段无效)→ 不抛、不弹', () async {
      final svc = _FakeService(
          () async => throw const FormatException('version 缺失/为空/类型错误'));
      final flow = AppUpdateFlow(service: svc, localVersion: _localV1);

      await expectLater(
        flow.autoCheckOnce(isAndroid: true, delay: Duration.zero),
        completes,
      );
      expect(flow.autoPromptUsed, isFalse);
      expect(svc.fetchCount, 1);
    });

    test('fetchLatest 返回旧版本(远端不高于本地)→ 不弹、闸门未消费', () async {
      final svc = _FakeService(() async => _info(version: '0.9.0', build: 3));
      final flow = AppUpdateFlow(service: svc, localVersion: _localV1);

      await flow.autoCheckOnce(isAndroid: true, delay: Duration.zero);

      expect(flow.autoPromptUsed, isFalse, reason: '未弹窗,下次启动仍可自动检查');
      expect(svc.fetchCount, 1);
    });

    test('失败不烧闸门:静默失败后再次自动检查仍会 fetch,拿到新版才消费', () async {
      var fail = true;
      final svc = _FakeService(() async {
        if (fail) throw const UpdateException('网络不可达,请检查网络后重试');
        return _info();
      });
      final flow = AppUpdateFlow(service: svc, localVersion: _localV1);

      await flow.autoCheckOnce(isAndroid: true, delay: Duration.zero);
      expect(flow.autoPromptUsed, isFalse);

      fail = false;
      await flow.autoCheckOnce(isAndroid: true, delay: Duration.zero);
      expect(svc.fetchCount, 2, reason: '失败路径不消费闸门,第二次仍尝试');
      expect(flow.autoPromptUsed, isTrue, reason: '闸门只在即将弹窗时消费');
    });
  });

  group('T6 取消语义(确认弹窗弹出即消费 session 闸门,D5)', () {
    test('无导航器:弹窗静默放弃但闸门已消费;第二次 autoCheckOnce 不再 fetch',
        () async {
      final svc = _FakeService(() async => _info(version: '9.9.9'));
      final flow = AppUpdateFlow(service: svc, localVersion: _localV1);

      await flow.autoCheckOnce(isAndroid: true, delay: Duration.zero);

      expect(flow.autoPromptUsed, isTrue,
          reason: '实现口径:闸门在即将弹窗时消费,导航未就绪同样算已弹'
              '(本 session 不再自动弹,手动入口不受影响)');
      expect(svc.fetchCount, 1);

      await flow.autoCheckOnce(isAndroid: true, delay: Duration.zero);
      expect(svc.fetchCount, 1, reason: '闸门已用,第二次直接短路,连 fetch 都不发生');
    });

    testWidgets('挂真实导航器:确认弹窗点「取消」→ 本 session 不再自动弹',
        (tester) async {
      final svc = _FakeService(() async => _info(version: '9.9.9'));
      final flow = AppUpdateFlow(service: svc, localVersion: _localV1);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: session.navigatorKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ));

      final fut = flow.autoCheckOnce(isAndroid: true, delay: Duration.zero);
      await tester.pump(); // 微任务:fetch 完成 → 消费闸门 → showDialog 建路由
      await tester.pumpAndSettle(); // 弹窗进场动画
      expect(find.text('发现新版本 9.9.9'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle(); // 弹窗退场
      await fut; // autoCheckOnce 收尾(取消 → 不进下载)
      expect(flow.autoPromptUsed, isTrue, reason: '取消也视为本 session 已弹过');

      // 同 session 第二次自动检查:不再 fetch、不再弹(下次启动才再提示)
      await flow.autoCheckOnce(isAndroid: true, delay: Duration.zero);
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 9.9.9'), findsNothing);
      expect(svc.fetchCount, 1, reason: '闸门已消费,第二次连 fetch 都不发生');
    });
  });
}
