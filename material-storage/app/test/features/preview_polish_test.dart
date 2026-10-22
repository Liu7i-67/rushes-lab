/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md 包 C 各条):
/// - C1 胶片条自动跟随:进入/切到靠后张时胶片条滚动位置变化(filmstrip.dart);
/// - C2 沉浸模式:单击媒体 AppBar/信息条隐、再击恢复(preview_page.dart);
/// - C3 双击缩放:双击后 InteractiveViewer scale>1、再双击复位(preview_media.dart);
/// - C5 下载入队就地反馈:点「下载」后按钮就地变为「已入队」类状态
///   (preview_page.dart,不再只有 SnackBar 浮出)。
/// app-polish-2 增补(G 包,对应 2026-10-22-app-polish-2.md):
/// - G1 胶片条恒居中:点选视口贴边项/横滑切张(含相邻已可见张)后当前张
///   一律 animateTo 居中(去「已完整可见则不滚」守卫);
/// - G2 缩略图优先:进入只签 thumbnail-url;放大(双击/捏合)>1.5x 签发一次
///   download-link 原图并 fade 替换(复位不回退);403 保持缩略图+P7 式提示。
///
/// 套路:同 preview_page_swipe_test.dart——内存假 API,网络图在测试区恒
/// errorBuilder,不影响手势与结构断言;全程逐 pump(缩略图 spinner 不定长,
/// pumpAndSettle 会挂)。页面级用例文本度量缩至 0.5(C3 改因:G2 起无缩略图
/// 资产入口走原图 inline,胶片条小格落 TypeBlock,Ahem 字体 48px 格需缩字防溢出)。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show ThumbnailImage, thumbnailCache;
import 'package:ms_app/features/preview/filmstrip.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';

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

/// G2:记录式假 API——thumbnail-url 即回假签名(缩略图优先直显),
/// download-link 记录入参(asAttachment 口径)且可编排抛错(403 用例)。
class _G2AssetsApi extends FakeAssetsApi {
  _G2AssetsApi(super.api);

  final thumbCalls = <String>[];
  final linkCalls = <({String id, bool asAttachment})>[];
  Object? linkStaged;

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) async {
    thumbCalls.add(assetId);
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }

  @override
  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async {
    linkCalls.add((id: assetId, asAttachment: asAttachment));
    final s = linkStaged;
    if (s is Exception) throw s;
    return 'http://presigned/$assetId';
  }
}

class _G2FakeMsApi extends FakeMsApi {
  late final _assets2 = _G2AssetsApi(this);

  @override
  _G2AssetsApi get assets => _assets2;
}

Asset _img(String id, {Map<String, dynamic> tags = const {'thumbnail_key': 'k'}}) =>
    Asset(
      id: id,
      filename: '$id.jpg',
      sizeBytes: 4,
      contentType: 'image/jpeg',
      createdAt: '2026-10-20T10:00:00Z',
      tags: tags,
    );

/// 挂预览页并落定首轮 loading(逐 pump,不用 pumpAndSettle)。
Future<void> _pumpPreview(WidgetTester tester, PreviewArgs args,
    {Object? linkThrows}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  installFakeApi(_PreviewFakeMsApi(linkThrows));
  addTearDown(() => session.api = null);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      // C3 改因(G2):无缩略图资产胶片条小格落 TypeBlock,Ahem 字体需缩字防溢出
      data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
      child: PreviewPage(args: args),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

/// 挂裸 PreviewMedia(G2 媒体状态机用,无胶片条无溢出噪音)并落定首轮。
Future<_G2AssetsApi> _pumpMedia(WidgetTester tester, Asset asset,
    {Object? linkStaged}) async {
  final fake = installFakeApi(_G2FakeMsApi()) as _G2FakeMsApi;
  fake.assets.linkStaged = linkStaged;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SizedBox.expand(child: PreviewMedia(asset: asset))),
  ));
  await tester.pump(); // _load 微任务:thumbnail-url 落地
  await tester.pump(); // Image 挂载帧
  return fake.assets;
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

/// 树上全部网络图 URL(G2 换源断言:缩略图/原图各一个特征地址)。
List<String> _imageUrls(WidgetTester tester) => tester
    .widgetList<Image>(find.byWidgetPredicate(
        (w) => w is Image && w.image is NetworkImage))
    .map((w) => (w.image as NetworkImage).url)
    .toList();

void main() {
  setUp(() => thumbnailCache.clear());

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

  // ── G1 胶片条恒居中 ─────────────────────────────────────────────────────
  testWidgets('G1:点选视口贴边(已完整可见)项后,该项滚至条中央',
      (tester) async {
    // 旧守卫口径:第 19 格(left=1020,right=1068 ⊆ [0,1080])已完整可见,
    // 点选直接 return 不滚——真机反馈「点击视口最后一个缩略图不居中」本源。
    final args = PreviewArgs(
      items: [for (var i = 1; i <= 60; i++) _img('g1a-$i')],
      index: 0,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_stripPixels(tester), closeTo(0, 2), reason: '前置:首张条在起点');

    // 步距=48+8(Tk.spaceSm)、条 padding 12:第 19 格(i=18)中心 1044,
    // 贴 1080 视口右缘且完整可见。点选后恒居中:target=1044-540=504。
    final cell = find.byType(ThumbnailImage).at(18);
    await tester.tap(cell);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('19 / 60'), findsOneWidget, reason: '前置:点选切张生效');
    expect(_stripPixels(tester), closeTo(504, 8),
        reason: 'G1:贴边可见项点选后恒居中(旧守卫保持 0 不滚)');
    // 几何复核走「当前张高亮格」(accent 描边唯一):.at(N) 在滚动后 ListView
    // 逐出头格时会漂移,不能复用作居中锚。
    final selected = find.descendant(
      of: find.byType(Filmstrip),
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border?.top.color == Tk.accent),
    );
    expect(tester.getCenter(selected).dx, closeTo(540, 8),
        reason: 'G1:被点项停在胶片条视口中央');
  });

  testWidgets('G1:横滑切到相邻(仍可见)张后也重居中,不再「可见即不动」',
      (tester) async {
    // 进入第 41 张:jumpTo 居中 target=12+40×56+24-540=1736;横滑到第 42 张
    // (旧守卫:第 42 格在视口内完整可见→不滚;新口径:恒 animateTo 1792)。
    final args = PreviewArgs(
      items: [for (var i = 1; i <= 60; i++) _img('g1b-$i')],
      index: 40,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_stripPixels(tester), closeTo(1736, 8), reason: '前置:41 张已居中');

    await tester.fling(find.byType(PreviewMedia), const Offset(-300, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('42 / 60'), findsOneWidget, reason: '前置:横滑切张生效');
    expect(_stripPixels(tester), closeTo(1792, 8),
        reason: 'G1:横滑切张后当前张恒居中(旧守卫会停在 1736 不动)');
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
    // 改因(G2):有缩略图资产入口改直显缩略图(thumbnailUrl 桩在本文件挂起),
    // 媒体区不会挂 InteractiveViewer;本用例锁的是双击缩放手势本体,改用
    // 无缩略图资产(既有原图 inline 路径,URL 即回)承载。
    final args = PreviewArgs(
      items: [
        _img('c3-1', tags: const {}),
        _img('c3-2', tags: const {}),
        _img('c3-3', tags: const {}),
      ],
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

  // ── G2 缩略图优先 + 放大换原图 ────────────────────────────────────────────
  testWidgets('G2:进入预览默认只签 thumbnail-url 直显缩略图,不签原图',
      (tester) async {
    final fake = await _pumpMedia(tester, _img('g2a-1'));

    expect(fake.thumbCalls, ['g2a-1'], reason: 'G2:入口走既有 thumbnail 通道');
    expect(fake.linkCalls, isEmpty,
        reason: 'G2:入口不再直接签 download-link 原图');
    expect(find.byType(InteractiveViewer), findsOneWidget,
        reason: '缩略图直显仍为图片分支(可放大)');
    expect(_imageUrls(tester), ['http://thumb.test/g2a-1'],
        reason: '渲染的是缩略图 URL');
    expect(find.textContaining('原图不可用'), findsNothing,
        reason: '缩略图正常直显,无 P7 提示');
    expect(find.text('预览加载失败'), findsNothing);
  });

  testWidgets('G2:放大(双击)>1.5x 签发一次原图;解码失败回退缩略图+提示,复位不重签(P2-1 改定)',
      (tester) async {
    final fake = await _pumpMedia(tester, _img('g2b-1'));
    final center = tester.getCenter(find.byType(PreviewMedia));
    expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: '前置:初始 1x');

    await _doubleTap(tester, center); // 2.5x > 1.5x 阈值
    await tester.pump(); // 签发微任务 + 换源 setState
    await tester.pump(const Duration(milliseconds: 400)); // 缩放动画+fade 完成
    expect(fake.linkCalls, const [(id: 'g2b-1', asAttachment: false)],
        reason: 'G2:放大越过 1.5x 签发一次 inline 原图(as_attachment:false)');
    expect(_mediaScale(tester), greaterThan(1.05),
        reason: 'G2:原图加载中缩放态不打断');

    // P2-1(测试实证缺陷修复):widget 测试区网络图恒 errorBuilder,即原图
    // 下载/解码失败路径——缩略图可用态回退保持缩略图 + P7 式提示(修复前
    // 直落「图片解码失败」失败卡)。pump 过 errorBuilder 后置帧回调与回退
    // fade(200ms)后断言稳定态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_imageUrls(tester), ['http://thumb.test/g2b-1'],
        reason: 'P2-1:原图解码失败回退缩略图渲染(非失败卡)');
    expect(find.textContaining('原图不可用'), findsOneWidget,
        reason: 'P2-1:与 403 路径同观感,叠不打断的 P7 式小字提示');
    expect(find.byType(InteractiveViewer), findsOneWidget,
        reason: 'P2-1:保持图片分支可放大(不落失败卡)');
    expect(_mediaScale(tester), greaterThan(1.05),
        reason: 'P2-1:回退不打断缩放态');

    await _doubleTap(tester, center); // 复位 1x
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: '前置:已复位');
    expect(fake.linkCalls.length, 1,
        reason: 'G2:签发去重——复位不重签(P2-1 回退态同样不重签)');
    expect(_imageUrls(tester), ['http://thumb.test/g2b-1'],
        reason: 'P2-1:回退态稳定,复位不再尝试原图');
  });

  testWidgets('G2:放大签原图 403 → 保持缩略图 + P7 式小字提示,缩放不打断',
      (tester) async {
    final fake = await _pumpMedia(tester, _img('g2c-1'),
        linkStaged: ApiException(403, '无下载权限'));
    final center = tester.getCenter(find.byType(PreviewMedia));

    await _doubleTap(tester, center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(fake.linkCalls.length, 1, reason: '前置:放大确有签发尝试');
    expect(_mediaScale(tester), greaterThan(1.05),
        reason: 'G2:签发失败缩放态不被打断');
    expect(_imageUrls(tester), ['http://thumb.test/g2c-1'],
        reason: 'G2:403 保持缩略图渲染');
    expect(find.textContaining('原图不可用'), findsOneWidget,
        reason: 'G2:叠不打断的 P7 式小字提示(沿用既有文案)');
    expect(find.text('预览加载失败'), findsNothing,
        reason: 'G2:失败不落失败卡(本来就是缩略图)');
  });
}
