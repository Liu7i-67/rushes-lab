/// P8(mobile-ux-polish)系统通知单测 + R4a(mobile-ux-polish-2)通知可达:
/// - transferNotifyTexts 纯函数口径(单文件详报带文件名/批量汇总/混合成败/
///   失败名单 3 个截断);
/// - TransferNotifyBatcher:前台 gate 丢弃、后台同窗聚合一条(99 张不逐张弹)、
///   上/下载各自聚一条、窗口触发后重开新批;定时器注入,零真实等待;
/// - Notifier:test 构造注入批/权限桩——taskFinished 路由与前台丢弃、
///   ensurePermission 幂等(多次调用至多请求一次)、init 失败静默降级
///   (单测环境无插件通道,单例批为空,终态上报不炸不产定时器);
/// - R4a:请求结果消费(授权态入内存)、被拒弹一次引导(二次入队不再弹/
///   已授权不弹/链路失败不弹)、queryPermission 注入查询与失败降级。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/services/notifier.dart';

void main() {
  group('transferNotifyTexts(纯函数口径)', () {
    test('单文件成功:标题带文件名,正文=保存摘要', () {
      final (title, body) = transferNotifyTexts(TransferKind.download, [
        const TransferNotifyEntry(ok: true, filename: 'a.jpg', detail: '已存入相册'),
      ]);
      expect(title, '下载完成:a.jpg');
      expect(body, '已存入相册');
    });

    test('单文件失败:标题带文件名,正文=简短原因', () {
      final (title, body) = transferNotifyTexts(TransferKind.upload, [
        const TransferNotifyEntry(ok: false, filename: 'b.mp4', detail: '空间不足'),
      ]);
      expect(title, '上传失败:b.mp4');
      expect(body, '空间不足');
    });

    test('单文件失败无原因:正文中文兜底(不裸渲染异常)', () {
      final (title, body) = transferNotifyTexts(TransferKind.upload, [
        const TransferNotifyEntry(ok: false, filename: 'b.mp4'),
      ]);
      expect(title, '上传失败:b.mp4');
      expect(body, '传输失败,请稍后重试');
    });

    test('批量全成功:一条汇总(完成:N 个文件)+ 名单正文', () {
      final (title, body) = transferNotifyTexts(TransferKind.upload, [
        const TransferNotifyEntry(ok: true, filename: '1.jpg'),
        const TransferNotifyEntry(ok: true, filename: '2.jpg'),
      ]);
      expect(title, '上传完成:2 个文件');
      expect(body, '1.jpg、2.jpg');
    });

    test('批量混合:k 成功 · m 失败汇总,正文只列失败名单', () {
      final (title, body) = transferNotifyTexts(TransferKind.download, [
        const TransferNotifyEntry(ok: true, filename: '1.jpg'),
        const TransferNotifyEntry(ok: false, filename: '2.jpg'),
        const TransferNotifyEntry(ok: true, filename: '3.jpg'),
      ]);
      expect(title, '下载完成:2 成功 · 1 失败');
      expect(body, contains('2.jpg'));
      expect(body, isNot(contains('1.jpg')), reason: '名单只列失败文件');
    });

    test('批量全失败:失败:N 个文件 + 名单', () {
      final (title, body) = transferNotifyTexts(TransferKind.upload, [
        const TransferNotifyEntry(ok: false, filename: 'a.jpg'),
        const TransferNotifyEntry(ok: false, filename: 'b.jpg'),
      ]);
      expect(title, '上传失败:2 个文件');
      expect(body, 'a.jpg、b.jpg');
    });

    test('名单超 3 截断:「等 N 个」收尾', () {
      final (title, body) = transferNotifyTexts(TransferKind.upload,
          [1, 2, 3, 4, 5].map((n) => TransferNotifyEntry(ok: true, filename: '$n.jpg')).toList());
      expect(title, '上传完成:5 个文件');
      expect(body, '1.jpg、2.jpg、3.jpg 等 5 个');
    });
  });

  group('TransferNotifyBatcher(定时器注入,零真实等待)', () {
    final sinkCalls = <(String, String)>[];
    final flushes = <void Function()>[];

    TransferNotifyBatcher build({required bool background}) =>
        TransferNotifyBatcher(
          sink: (t, b) async => sinkCalls.add((t, b)),
          gate: () => background,
          schedule: (_, cb) => flushes.add(cb),
        );

    tearDown(() {
      sinkCalls.clear();
      flushes.clear();
    });

    test('前台完成:gate false → 不入批不调度,不发通知', () {
      final b = build(background: false);
      b.add(TransferKind.upload, const TransferNotifyEntry(ok: true, filename: 'a.jpg'));
      expect(flushes, isEmpty, reason: '前台丢弃,连聚合定时器都不挂');
      for (final f in List.of(flushes)) {
        f();
      }
      expect(sinkCalls, isEmpty);
    });

    test('后台同窗 99 张上传完成 → 只挂一个定时器,到期一条汇总(防轰炸)', () {
      final b = build(background: true);
      for (var i = 0; i < 99; i++) {
        b.add(TransferKind.upload,
            TransferNotifyEntry(ok: true, filename: 'f$i.jpg'));
      }
      expect(flushes.length, 1, reason: '窗口内只挂一个聚合定时器');
      flushes.removeAt(0)();
      expect(sinkCalls.length, 1, reason: '99 张只发一条系统通知');
      expect(sinkCalls.single.$1, '上传完成:99 个文件');
    });

    test('上/下载同窗各聚一条(两类互不混)', () {
      final b = build(background: true);
      b.add(TransferKind.upload, const TransferNotifyEntry(ok: true, filename: 'u1.jpg'));
      b.add(TransferKind.download,
          const TransferNotifyEntry(ok: true, filename: 'd1.jpg', detail: '已存入相册'));
      b.add(TransferKind.upload, const TransferNotifyEntry(ok: false, filename: 'u2.jpg'));
      flushes.removeAt(0)();
      expect(sinkCalls.length, 2);
      expect(sinkCalls.map((c) => c.$1), containsAll(<String>[
        '上传完成:1 成功 · 1 失败',
        '下载完成:d1.jpg',
      ]));
    });

    test('窗口触发后重开新批:第二批重新计窗再聚一条', () {
      final b = build(background: true);
      b.add(TransferKind.upload, const TransferNotifyEntry(ok: true, filename: 'a.jpg'));
      flushes.removeAt(0)(); // 第一窗到期(单文件详报口径)
      expect(sinkCalls.single.$1, '上传完成:a.jpg');

      b.add(TransferKind.upload, const TransferNotifyEntry(ok: true, filename: 'b.jpg'));
      b.add(TransferKind.upload, const TransferNotifyEntry(ok: true, filename: 'c.jpg'));
      expect(flushes.length, 1, reason: '新批重新计窗');
      flushes.removeAt(0)();
      expect(sinkCalls.length, 2);
      expect(sinkCalls.last.$1, '上传完成:2 个文件');
    });

    test('批内混合成败聚合:k 成功 · m 失败(单批口径)', () {
      final b = build(background: true);
      b.add(TransferKind.download, const TransferNotifyEntry(ok: true, filename: '1.jpg'));
      b.add(TransferKind.download, const TransferNotifyEntry(ok: false, filename: '2.jpg', detail: '空间不足'));
      flushes.removeAt(0)();
      expect(sinkCalls.single.$1, '下载完成:1 成功 · 1 失败');
      expect(sinkCalls.single.$2, '失败:2.jpg');
    });

    test('sink 抛异常不炸批器:不外泄,下一批照发(通知失败不影响业务流)', () async {
      final ok = <(String, String)>[];
      var failFirst = true;
      final batcher = TransferNotifyBatcher(
        sink: (t, b) async {
          if (failFirst) {
            failFirst = false;
            throw StateError('notify channel dead');
          }
          ok.add((t, b));
        },
        gate: () => true,
        schedule: (_, cb) => flushes.add(cb),
      );

      batcher.add(TransferKind.upload,
          const TransferNotifyEntry(ok: true, filename: 'a.jpg'));
      flushes.removeAt(0)(); // 第一批:sink 抛(被 catchError 吞,不外泄)
      await Future<void>.delayed(Duration.zero);

      batcher.add(TransferKind.upload,
          const TransferNotifyEntry(ok: true, filename: 'b.jpg'));
      flushes.removeAt(0)(); // 第二批:照常聚合发出
      await Future<void>.delayed(Duration.zero);
      expect(ok.single.$1, '上传完成:b.jpg', reason: 'sink 异常后批器仍可用');
    });
  });

  group('Notifier(test 注入)', () {
    test('taskFinished 经批器路由到 sink;前台丢弃', () {
      final calls = <(String, String)>[];
      var background = true;
      final flushes = <void Function()>[];
      final notifier = Notifier.test(
        batcher: TransferNotifyBatcher(
          sink: (t, b) async => calls.add((t, b)),
          gate: () => background,
          schedule: (_, cb) => flushes.add(cb),
        ),
      );
      notifier.taskFinished(
          kind: TransferKind.download,
          ok: true,
          filename: 'a.jpg',
          detail: '已存入相册');
      flushes.removeAt(0)();
      expect(calls.single, ('下载完成:a.jpg', '已存入相册'));

      background = false; // 前台:终态丢弃
      notifier.taskFinished(
          kind: TransferKind.download, ok: false, filename: 'b.jpg');
      expect(flushes, isEmpty, reason: '前台不入批不调度');
    });

    test('ensurePermission 幂等:多次入队触发至多请求一次权限', () async {
      var asked = 0;
      final notifier = Notifier.test(
        batcher: TransferNotifyBatcher(
          sink: (_, _) async {},
          gate: () => true,
          schedule: (_, _) {},
        ),
        permission: () async {
          asked++;
          return true;
        },
      );
      for (var i = 0; i < 3; i++) {
        await notifier.ensurePermission();
      }
      expect(asked, 1, reason: '本会话至多请求一次(系统侧「未决才弹」由 OS 保证)');
      expect(notifier.permissionAsked, isTrue);
      expect(notifier.permissionGranted, isTrue, reason: 'R4a:授权态入内存');
    });

    test('R4a:请求后仍被拒 → 弹一次引导;二次入队不再弹(会话内至多一次)', () async {
      var asked = 0;
      var guides = 0;
      final notifier = Notifier.test(
        batcher: TransferNotifyBatcher(
          sink: (_, _) async {},
          gate: () => true,
          schedule: (_, _) {},
        ),
        permission: () async {
          asked++;
          return false; // 请求了但用户拒绝
        },
        guide: () async => guides++,
      );
      await notifier.ensurePermission();
      expect(asked, 1);
      expect(guides, 1, reason: '被拒 → 引导一次');
      expect(notifier.permissionGranted, isFalse);
      expect(notifier.guideShown, isTrue);

      // 第二次入队:_permissionAsked 已挡,不再请求也不再引导(防骚扰口径)
      await notifier.ensurePermission();
      expect(asked, 1);
      expect(guides, 1);
    });

    test('R4a:已授权不弹引导;null 结果(<13/iOS 无结论)视为可用也不弹', () async {
      var guides = 0;
      Notifier build(Future<bool?> Function() p) => Notifier.test(
            batcher: TransferNotifyBatcher(
              sink: (_, _) async {},
              gate: () => true,
              schedule: (_, _) {},
            ),
            permission: p,
            guide: () async => guides++,
          );
      await build(() async => true).ensurePermission();
      expect(guides, 0, reason: '已授权不弹');
      await build(() async => null).ensurePermission();
      expect(guides, 0, reason: '系统未给结论 → 视为可用');
    });

    test('R4a:请求链路失败 ≠ 拒绝 → 不弹引导,授权态保持 null', () async {
      var guides = 0;
      final notifier = Notifier.test(
        batcher: TransferNotifyBatcher(
          sink: (_, _) async {},
          gate: () => true,
          schedule: (_, _) {},
        ),
        permission: () async => throw StateError('channel dead'),
        guide: () async => guides++,
      );
      await notifier.ensurePermission();
      expect(guides, 0, reason: '链路失败静默降级,不引导');
      expect(notifier.permissionGranted, isNull);
    });

    test('R4a:queryPermission 注入查询直通;单例真实路径无插件通道降级为已开启',
        () async {
      final notifier = Notifier.test(
        batcher: TransferNotifyBatcher(
          sink: (_, _) async {},
          gate: () => true,
          schedule: (_, _) {},
        ),
        queryPermission: () async => false,
      );
      expect(await notifier.queryPermission(), isFalse);
      // 单例(真实路径):单测无平台通道 → 查询失败 → 降级 true(不误报未开启)
      expect(await Notifier.I.queryPermission(), isTrue);
    });

    test('init 失败静默降级:单测无插件通道,单例终态上报不炸不产定时器', () async {
      // 无平台通道 → initialize 抛错被 init 捕获 → 单例批为空(降级)
      await Notifier.I.init();
      // 终态上报 no-op:不抛错、不挂任何定时器(若挂了真实 Timer,flutter_test
      // 会以 pending timer 报错——本用例即防回归钉子)
      Notifier.I.taskFinished(
          kind: TransferKind.upload, ok: true, filename: 'x.jpg');
      await Notifier.I.ensurePermission();
    });
  });

  group('R4a 引导框(widget)', () {
    testWidgets('文案钉死:标题「开启系统通知」+ 用途正文 + 去设置/取消;取消可关',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => FilledButton(
            onPressed: () => Notifier.I.showNotificationGuideDialog(ctx),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('开启系统通知'), findsOneWidget);
      expect(find.textContaining('系统通知权限'), findsOneWidget,
          reason: '正文说明后台传输完成提醒用途');
      expect(find.text('去设置'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      // 只点取消(去设置会触平台通道,不在单测覆盖)
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('开启系统通知'), findsNothing);
    });
  });
}
