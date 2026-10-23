/// 边界补测(测试子智能体):更新弹窗行为面 + downloadAndInstall 期间
/// context unmount 的收口行为。
/// - 确认弹窗:超长 changelog 走 SingleChildScrollView;点 barrier(dismiss)
///   返回 false=取消(实现口径,允许);
/// - 进度弹窗:barrier 不可点关;
/// - unmount 场景:下载进行中整棵树被移除,downloadAndInstall 不崩、future 收口。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/update/apk_updater.dart';
import 'package:ms_app/core/update/app_version_info.dart';
import 'package:ms_app/core/update/update_dialogs.dart';
import 'package:ms_app/core/update/update_flow.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/theme/tk_colors.dart';

AppVersionInfo _info({String changelog = ''}) => AppVersionInfo(
  version: '9.9.9',
  build: 1,
  changelog: changelog,
  force: false,
  androidUrl: 'https://cdn/huanhuashijie-9.9.9.apk',
);

void main() {
  group('确认弹窗边界', () {
    testWidgets('超长 changelog:正文包在 SingleChildScrollView 内且首行可见', (
      tester,
    ) async {
      final long = '一行说明。\n${List.filled(200, '很长的更新说明文字。').join()}';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showUpdateConfirmDialog(
                    context,
                    info: _info(changelog: long),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      expect(find.text('发现新版本 9.9.9'), findsOneWidget);
      expect(
        find.byType(SingleChildScrollView),
        findsOneWidget,
        reason: '超长 changelog 必须可滚动',
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('一行说明'), findsOneWidget, reason: '首行在可视区内');
      expect(
        find.textContaining('很长的更新说明文字', findRichText: true),
        findsWidgets,
        reason: '正文有渲染(滚动容器内)',
      );
    });

    testWidgets('点 barrier 关闭(dismiss)→ 返回 false=取消口径', (tester) async {
      late Future<bool> fut;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      fut = showUpdateConfirmDialog(context, info: _info()),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 9.9.9'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10)); // barrier 区
      await tester.pumpAndSettle();

      expect(await fut, isFalse, reason: 'dismiss=取消(实现口径)');
      expect(find.text('发现新版本 9.9.9'), findsNothing);
    });

    testWidgets('墨金主题:标题 20 / 正文 14 ink2 / 主按钮金 / 遮罩 scrim', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showUpdateConfirmDialog(
                    context,
                    info: _info(changelog: '修复若干问题'),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      const tk = TkColors.dark;
      expect(
        DefaultTextStyle.of(tester.element(find.text('发现新版本 9.9.9')))
            .style
            .fontSize,
        20,
        reason: '弹层标题 20 交 DialogTheme',
      );
      final body = tester.widget<Text>(find.text('修复若干问题'));
      expect(body.style?.fontSize, 14);
      expect(body.style?.color, tk.ink2);

      final confirm = find.widgetWithText(FilledButton, '立即更新');
      final confirmBg = tester.widget<Material>(
        find.descendant(of: confirm, matching: find.byType(Material)).first,
      );
      expect(confirmBg.color, tk.gold, reason: '主按钮金');
      final cancel = find.widgetWithText(TextButton, '取消');
      final cancelBg = tester.widget<Material>(
        find.descendant(of: cancel, matching: find.byType(Material)).first,
      );
      expect(cancelBg.color, Colors.transparent, reason: '次按钮 ghost');
      expect(
        tester.widgetList<ModalBarrier>(find.byType(ModalBarrier)).last.color,
        tk.scrim,
      );
    });
  });

  group('进度弹窗边界', () {
    testWidgets('barrier 点外不关闭(barrierDismissible=false)', (tester) async {
      final progress = ValueNotifier<int>(42);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showUpdateProgressDialog(
                    context,
                    progress: progress,
                    onCancel: () {},
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      expect(find.text('42%'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('正在下载更新'), findsOneWidget, reason: '进度弹窗 barrier 不可点关');
    });

    testWidgets('未知总长(-1)落进行中态;取消按钮触发回调', (tester) async {
      final progress = ValueNotifier<int>(-1);
      var cancelled = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showUpdateProgressDialog(
                    context,
                    progress: progress,
                    onCancel: () => cancelled++,
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      // 注意:indeterminate LinearProgressIndicator 永不静止,禁止 pumpAndSettle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('下载中…'), findsOneWidget, reason: '-1=总长未知,进行中态');

      progress.value = 100;
      await tester.pump();
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(cancelled, 1);
    });

    testWidgets('墨金主题:进度条金色、surface3 轨道、百分比 goldInk', (tester) async {
      final progress = ValueNotifier<int>(42);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showUpdateProgressDialog(
                    context,
                    progress: progress,
                    onCancel: () {},
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();

      const tk = TkColors.dark;
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.backgroundColor, tk.surface3);
      expect(
        (bar.valueColor as AlwaysStoppedAnimation<Color>).value,
        tk.gold,
        reason: '进度金',
      );
      final percent = tester.widget<Text>(find.text('42%'));
      expect(percent.style?.color, tk.goldInk);
      expect(percent.style?.fontFeatures, isNotNull, reason: '百分比数字等宽');
    });
  });

  group('downloadAndInstall unmount 收口(边界)', () {
    testWidgets('下载中整棵树被移除(context unmounted):观察收口行为', (tester) async {
      final gate = Completer<void>();
      final updater = _HangingApkUpdater(gate);
      final settled = Completer<void>(); // downloadAndInstall 落定镜像
      Future<void>? flowFut;

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: session.navigatorKey,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () {
                    final flow = AppUpdateFlow(
                      updater: updater,
                      localVersion: () async => (version: '1.0.0', build: 1),
                    );
                    flowFut = flow.downloadAndInstall(context, info: _info());
                    unawaited(flowFut!.whenComplete(settled.complete));
                  },
                  child: const Text('GO'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('GO'));
      await tester.pumpAndSettle();
      expect(find.text('正在下载更新'), findsOneWidget);

      // 整棵树(含 root navigator 与进度弹窗)被移除:复刻 401 强制登出
      // (session.pushNamedAndRemoveUntil('/', (r) => false))把弹窗一并撤走的场景
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      // 下载完成 → closeDialog 走 Navigator.of(已失活 context)
      gate.complete();
      await tester.pump();
      // 推进假时钟 10s:若 future 收口,settled 必已完成
      await tester.pump(const Duration(seconds: 10));

      // 当前实现口径(已报问题):closeDialog 对失活 context 做 Navigator.of
      // 抛错,且 dialogFuture(路由被移除时 popped 永不完成)令 finally 永久挂起
      // → downloadAndInstall 不收口、progress ValueNotifier 不 dispose。
      // 本断言固化「当前挂起」事实;修复后应改为 expect(settled.isCompleted, isTrue)。
      expect(
        settled.isCompleted,
        isFalse,
        reason:
            '已知问题:unmount 后 downloadAndInstall 挂起不收口'
            '(见测试报告 P2;修复本用例后请同步翻转断言)',
      );
      expect(
        tester.takeException(),
        isNull,
        reason: '异常被挂起的 finally 悬置,不冒泡到 zone',
      );
    });
  });
}

/// 下载挂起变体(下载 futures 由 gate 控制收放,复刻「下载中」窗口期)。
class _HangingApkUpdater extends ApkUpdater {
  _HangingApkUpdater(this.gate)
    : super(
        dio: Dio(),
        tempDirPath: () async => Directory.systemTemp.path,
        openApk: (_) async => (done: true, message: ''),
      );

  final Completer<void> gate;

  @override
  Future<void> download({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    required void Function(int percent) onProgress,
  }) async {
    onProgress(0);
    await gate.future;
  }
}
