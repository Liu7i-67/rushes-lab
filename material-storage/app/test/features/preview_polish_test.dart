/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md 包 C 各条):
/// - C1 胶片条自动跟随:进入/切到靠后张时胶片条滚动位置变化(filmstrip.dart);
/// - C2 沉浸模式:单击媒体 AppBar/信息条隐、再击恢复(preview_page.dart);
/// - C3 双击缩放:双击后 InteractiveViewer scale>1、再双击复位(preview_media.dart);
/// - C5 下载入队就地反馈:点「下载」后按钮就地变为「已入队」类状态
///   (preview_page.dart,不再只有 SnackBar 浮出)。
///
/// 套路:同 preview_page_swipe_test.dart——内存假 API(downloadLink 即回假
/// URL / thumbnailUrl 永挂起避 spinner 噪音),网络图在测试区恒 errorBuilder,
/// 不影响手势与结构断言;全程逐 pump(缩略图 spinner 不定长,pumpAndSettle 会挂)。
/// 凡依赖「尚未存在的行为」的断言均标注 TODO(app-polish Cx):现状应失败,
/// 交付后转绿。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/preview/filmstrip.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// C1-C3:downloadLink 即回假 URL(图片分支挂 InteractiveViewer);
/// thumbnailUrl 永挂起(胶片条小格停 spinner,避开 TypeBlock 溢出噪音)。
class _PreviewAssetsApi extends FakeAssetsApi {
  _PreviewAssetsApi(super.api, {this.linkThrows});

  final Object? linkThrows;

  @override
  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async {
    final t = linkThrows;
    if (t is Exception) throw t;
    return 'http://presigned/$assetId';
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) =>
      Completer<({String url, int expiresIn})>().future;
}

class _PreviewFakeMsApi extends FakeMsApi {
  _PreviewFakeMsApi(Object? linkThrows) : _linkThrows = linkThrows;

  final Object? _linkThrows;

  late final _assets2 = _PreviewAssetsApi(this, linkThrows: _linkThrows);

  @override
  _PreviewAssetsApi get assets => _assets2;
}

Asset _img(String id) => Asset(
      id: id,
      filename: '$id.jpg',
      sizeBytes: 4,
      contentType: 'image/jpeg',
      createdAt: '2026-10-20T10:00:00Z',
      tags: const {'thumbnail_key': 'k'},
    );

/// 挂预览页并落定首轮 loading(逐 pump,不用 pumpAndSettle)。
Future<void> _pumpPreview(WidgetTester tester, PreviewArgs args,
    {Object? linkThrows}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  installFakeApi(_PreviewFakeMsApi(linkThrows));
  addTearDown(() => session.api = null);
  await tester.pumpWidget(MaterialApp(home: PreviewPage(args: args)));
  await tester.pump();
  await tester.pump();
}

/// 胶片条横向滚动位置(ListView 内 Scrollable 的 pixels)。
double _stripPixels(WidgetTester tester) {
  final scrollable = find
      .descendant(of: find.byType(Filmstrip), matching: find.byType(Scrollable))
      .first;
  return tester.state<ScrollableState>(scrollable).position.pixels;
}

/// 模拟双击:两次快速 tap(间隔 kDoubleTapMinTime,进 doubleTap 认定窗口)。
Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  final g1 = await tester.startGesture(at);
  await g1.up();
  await tester.pump(kDoubleTapMinTime);
  final g2 = await tester.startGesture(at);
  await g2.up();
  await tester.pump();
}

/// 双击缩放读数:InteractiveViewer 变换矩阵的最大轴缩放。
double _mediaScale(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value
    .getMaxScaleOnAxis();

void main() {
  // ── C1 胶片条自动跟随 ───────────────────────────────────────────────────
  testWidgets('C1:初始定位靠后张/横滑切张后,胶片条滚动位置跟随变化',
      (tester) async {
    final args = PreviewArgs(
      items: [for (var i = 1; i <= 60; i++) _img('c1-$i')],
      index: 40, // 第 41 张:远超胶片条一屏(~20 格),跟随必须滚动
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    expect(find.text('41 / 60'), findsOneWidget, reason: '前置:定位第 41 张');

    // 给 animateTo(若有)留动画时间
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // TODO(app-polish C1): 现状应失败(胶片条无 ScrollController,恒在 0),
    // 交付后转绿
    expect(_stripPixels(tester), greaterThan(0),
        reason: 'C1:进入靠后张,胶片条应自动滚动让当前张可见');

    // 横滑切到下一张,跟随保持
    await tester.fling(find.byType(PreviewMedia), const Offset(-300, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('42 / 60'), findsOneWidget, reason: '前置:横滑切张生效');
    expect(_stripPixels(tester), greaterThan(0),
        reason: 'C1:切张后胶片条跟随(仍指向当前张)');
  });

  // ── C2 沉浸模式 ─────────────────────────────────────────────────────────
  testWidgets('C2:单击媒体进入沉浸(AppBar/胶片条 offstage),再单击恢复',
      (tester) async {
    final args = PreviewArgs(
      items: [_img('c2-1'), _img('c2-2'), _img('c2-3')],
      index: 0,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(Filmstrip), findsOneWidget, reason: '前置:多文件有胶片条');

    await tester.tap(find.byType(PreviewMedia));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // TODO(app-polish C2): 现状应失败(单击无响应),交付后转绿。
    // 验收口径=测试功能点「AppBar/信息条 offstage」:实现须用 Offstage/等价
    // 「树上不可见」机制(find 默认 skipOffstage)。
    expect(find.byType(AppBar), findsNothing, reason: 'C2:沉浸态 AppBar 隐去');
    expect(find.byType(Filmstrip), findsNothing, reason: 'C2:沉浸态胶片条隐去');
    expect(find.text('1 / 3'), findsNothing, reason: 'C2:顶部计数随 AppBar 隐去');

    // 再单击恢复
    await tester.tap(find.byType(PreviewMedia));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AppBar), findsOneWidget, reason: 'C2:再单击恢复 AppBar');
    expect(find.byType(Filmstrip), findsOneWidget, reason: 'C2:再单击恢复胶片条');
  });

  // ── C3 双击缩放 ─────────────────────────────────────────────────────────
  testWidgets('C3:双击图片 scale 升到 >1(规格 2.5x),再双击复位 1x',
      (tester) async {
    final args = PreviewArgs(
      items: [_img('c3-1'), _img('c3-2'), _img('c3-3')],
      index: 0,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    // 再补两帧:等 downloadLink 微任务落地、Image.network 错误帧走完,
    // InteractiveViewer(图片分支)已挂载
    await tester.pump();
    await tester.pump();
    final center = tester.getCenter(find.byType(PreviewMedia));
    expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: '前置:初始 1x');

    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
    // TODO(app-polish C3): 现状应失败(无双击手势,恒 1x),交付后转绿
    expect(_mediaScale(tester), greaterThan(1.05),
        reason: 'C3:双击放大(目标 2.5x,仅断言 >1 不钉具体动画实现)');

    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_mediaScale(tester), closeTo(1.0, 0.05),
        reason: 'C3:再双击复位 1x');
  });

  // ── C5 下载入队就地反馈 ─────────────────────────────────────────────────
  testWidgets('C5:点「下载」入队后按钮就地变为「已入队」类状态',
      (tester) async {
    final args = PreviewArgs(
      items: [_img('c5-1')],
      index: 0,
      folderId: 'f1',
      canDownload: true,
      where: '项目A/夹B',
    );
    // downloadLink 抛 403:入队后的 worker 立即终态,避免悬挂任务/IO
    await _pumpPreview(tester, args, linkThrows: ApiException(403, '无下载权限'));
    expect(find.text('下载'), findsOneWidget, reason: '前置:下载钮点亮');

    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.pump();
    // TODO(app-polish C5): 现状应失败(只有 SnackBar「已加入下载队列:…」,
    // 按钮无就地状态),交付后转绿
    expect(find.textContaining('已入队'), findsWidgets,
        reason: 'C5:下载钮就地状态变化(入队中→已入队 ✓)');
    // 收尾:排空已入队复原 Timer 与队列 worker 计时器。改因(app-polish C5
    // 交付):本用例 downloadLink 恒 403→缩略图桩件永挂起,媒体区加载圈为
    // 不定长动画,pumpAndSettle 必挂(与 _pumpPreview 注释同源),改逐 pump 排空。
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
  });
}
