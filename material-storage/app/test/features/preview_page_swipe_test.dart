/// P3(mobile-ux-polish)预览页横滑切张单测:
/// - AppBar 去左右切换钮,保留 n / N 计数 + 文件名;
/// - 单指左滑下一张/右滑上一张,边界即停;
/// - 与 InteractiveViewer 协作:未放大单指横滑切页(图片分支 arena 归内层
///   scale 识别器,经 onSwipe 内层路上报,两路不双触发);双指捏合放大后拖动
///   为平移不切页(onZoomChanged 回报,外层 _mediaZoomed 双保险);捏回原大
///   复位后可再滑切。
/// API 内存假件(G2 改因):资产一律不带 thumbnail_key——图片入口走既有原图
/// inline 路径(downloadLink 即回假 URL),媒体区照常挂 InteractiveViewer,
/// 捏合/拖动手势断言与媒体加载来源无关;胶片条小格直出 TypeBlock,由下方
/// textScaler 0.5 缩字防溢出(同 preview_swipe_test 形态);thumbnailUrl 挂起
/// (hasThumbnail=false 恒不触发,兜底防串)。
/// 网络图在 widget 测试区恒错误→errorBuilder,不影响手势与滑切断言。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

class _SwipeAssetsApi extends FakeAssetsApi {
  _SwipeAssetsApi(super.api);

  @override
  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async =>
      'http://presigned/$assetId';

  /// 永挂起:G2 后仅 hasThumbnail 资产才会请求;本文件资产均无 thumbnail_key。
  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) =>
      Completer<({String url, int expiresIn})>().future;
}

class _SwipeFakeMsApi extends FakeMsApi {
  late final _assets2 = _SwipeAssetsApi(this);

  @override
  _SwipeAssetsApi get assets => _assets2;
}

PreviewArgs _args() => PreviewArgs(
      items: [
        for (var i = 1; i <= 3; i++)
          Asset(
              id: 'p3-$i',
              filename: 'p3-$i.jpg',
              sizeBytes: 4,
              contentType: 'image/jpeg',
              createdAt: '2026-10-20T10:00:00Z'), // G2 改因:无 thumbnail_key
      ],
      index: 0,
      folderId: 'f1',
      canDownload: true,
    );

Asset _assetOf(String id, String filename, String? ct) => Asset(
      id: id,
      filename: filename,
      sizeBytes: 4,
      contentType: ct,
      createdAt: '2026-10-20T10:00:00Z',
    );

/// 混排:图片 + pdf(非图片张;测试平台非 iOS → 恒「下载后打开」失败卡,无
/// InteractiveViewer、零网络零定时器)+ 图片——复现「放大图片张 → 胶片条跳
/// 非图片张 → 横滑失活」的最小场景(P1-1)。
PreviewArgs _argsMixed() => PreviewArgs(
      items: [
        _assetOf('p3-1', 'p3-1.jpg', 'image/jpeg'),
        _assetOf('p3-doc', 'p3-doc.pdf', 'application/pdf'),
        _assetOf('p3-3', 'p3-3.jpg', 'image/jpeg'),
      ],
      index: 0,
      folderId: 'f1',
      canDownload: true,
    );

Future<void> _pump(WidgetTester tester, [PreviewArgs? args]) async {
  // 放大测试台面:默认 800x600 下 MetaPanel/操作栏挤压(与被测逻辑无关的
  // 布局噪音)
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  installFakeApi(_SwipeFakeMsApi());
  addTearDown(() => session.api = null);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      // G2 改因:小格改直出 TypeBlock(Ahem 行高偏大,48px 格内假性溢出),
      // 缩小文本度量只影响测试渲染,与被测的横滑/捏合断言无关(同
      // preview_swipe_test 口径)
      data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
      child: PreviewPage(args: args ?? _args()),
    ),
  ));
  await tester.pump(); // _load 微任务:URL 即回,Image.network 错误走 errorBuilder
  await tester.pump();
}

/// 双指捏合:指间距由 from 变到 to(每步 pump 推进识别器与 InteractiveViewer)。
/// 左指(f1)从 center-from/2 到 center-to/2:位移 = (from-to)/2/8,右指反向。
Future<void> _pinch(WidgetTester tester, Offset center,
    {required double from, required double to}) async {
  final f1 = await tester.startGesture(center - Offset(from / 2, 0));
  final f2 = await tester.startGesture(center + Offset(from / 2, 0));
  await tester.pump();
  final step = (to - from) / 2 / 8;
  for (var i = 0; i < 8; i++) {
    await f1.moveBy(Offset(-step, 0)); // 左指左移张开/右移收拢
    await f2.moveBy(Offset(step, 0)); // 右指镜像
    await tester.pump();
  }
  await f1.up();
  await f2.up();
  await tester.pump();
}

void main() {
  testWidgets('AppBar 无切换钮,保留 n / N 计数与文件名', (tester) async {
    await _pump(tester);
    expect(find.byIcon(Icons.chevron_left), findsNothing,
        reason: 'P3 去顶部左右切换钮');
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.text('1 / 3'), findsOneWidget);
    // 文件名在 AppBar 与 MetaPanel 各一处
    expect(
      find.descendant(
          of: find.byType(AppBar), matching: find.text('p3-1.jpg')),
      findsOneWidget,
    );
  });

  testWidgets('横滑切张:左滑下一张/右滑上一张,边界即停', (tester) async {
    await _pump(tester);
    final media = find.byType(PreviewMedia);

    // 首张右滑:边界即停
    await tester.drag(media, const Offset(400, 0));
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);

    // 左滑 → 2 / 3;再左滑 → 3 / 3
    await tester.drag(media, const Offset(-400, 0));
    await tester.pump();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.drag(media, const Offset(-400, 0));
    await tester.pump();
    expect(find.text('3 / 3'), findsOneWidget);

    // 末张左滑:边界即停;右滑回退
    await tester.drag(media, const Offset(-400, 0));
    await tester.pump();
    expect(find.text('3 / 3'), findsOneWidget, reason: '末张不可后翻');
    await tester.drag(media, const Offset(400, 0));
    await tester.pump();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('与 InteractiveViewer 协作:捏合放大后拖动不切页,捏回原大可再滑切',
      (tester) async {
    await _pump(tester);
    final media = find.byType(PreviewMedia);
    final center = tester.getCenter(media);

    // 双指张开放大(scale 顶到 maxScale 4)
    await _pinch(tester, center, from: 80, to: 680);
    expect(find.text('1 / 3'), findsOneWidget);

    // 放大态单指横滑:平移图片,不切页
    await tester.drag(media, const Offset(-400, 0));
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget, reason: '放大后拖动为平移,不切页');

    // 双指捏回原大:复位交还横滑
    await _pinch(tester, center, from: 400, to: 40);
    expect(find.text('1 / 3'), findsOneWidget);

    // 复位后再滑:可切页
    await tester.drag(media, const Offset(-400, 0));
    await tester.pump();
    expect(find.text('2 / 3'), findsOneWidget, reason: '捏回原大后横滑恢复切页');
  });

  testWidgets('P1-1 缺陷回归:放大态经胶片条跳张后,横滑不失活(切张复位缩放态)',
      (tester) async {
    // 复现:双指放大第 1 张图片 → 胶片条跳非图片张(pdf,恒失败卡)→ 单指横滑
    // 应切页;修复前 _mediaZoomed 残留 → 外层拖动回调置空 → 横滑永久失活。
    await _pump(tester, _argsMixed());
    final media = find.byType(PreviewMedia);
    final center = tester.getCenter(media);

    // ① 双指放大第 1 张(图片)
    await _pinch(tester, center, from: 80, to: 680);
    expect(find.text('1 / 3'), findsOneWidget);

    // ② 胶片条跳到第 2 张(pdf 非图片张)
    await tester.tap(find.byType(ThumbnailImage).at(1));
    await tester.pump();
    await tester.pump();
    expect(find.text('2 / 3'), findsOneWidget);

    // ③ 修复点:跳张后单指横滑恢复切页(pdf 失败卡中心无命中叶子,warn 关)
    await tester.drag(media, const Offset(-400, 0), warnIfMissed: false);
    await tester.pump();
    expect(find.text('3 / 3'), findsOneWidget, reason: '跳张后横滑不得失活');

    // ④ 对照组:跳回图片张再放大,放大态横滑仍不切页(门控语义不回退)
    await tester.tap(find.byType(ThumbnailImage).at(0));
    await tester.pump();
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);
    await _pinch(tester, center, from: 80, to: 680);
    await tester.drag(media, const Offset(-400, 0));
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget, reason: '放大态横滑仍不切页');
  });
}
