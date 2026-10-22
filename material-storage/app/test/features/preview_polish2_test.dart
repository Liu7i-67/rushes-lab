/// app-polish-2(P2 批)预览包验收用例(对应需求文档 2026-10-22-app-polish-2.md):
/// - G1(#2) 胶片条恒居中跟随:去掉「已完整可见则不滚」守卫——点选视口内
///   贴边可见项后该项滚至条中央(offset 断言);横滑到屏外张后跟随(保留语义);
/// - G2(#3) 缩略图优先+放大换原图:进入预览仅请求 thumbnail-url、未签
///   download-link(fake api 记录);放大(双击,2.5x>1.5x 阈值)后签发原图
///   恰好一次、双击复位不重签;放大签发 403 → 保持缩略图 + P7 式小字提示。
///
/// 套路:同 preview_polish_test.dart——内存假 API(downloadLink 即回假 URL /
/// 可编排 403;thumbnailUrl 记录调用并回假地址),网络图在测试区恒
/// errorBuilder,不影响手势与 API 记录断言;全程逐 pump(加载圈为不定长
/// 动画,勿 pumpAndSettle)。G1/G2 已交付,先红阶段的 TODO 标注已摘除。
library;

import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart' show ThumbnailImage, thumbnailCache;
import 'package:ms_app/features/preview/filmstrip.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';

import '../helpers/api_harness.dart';

// filmstrip.dart 布局常量同源(与 build 段保持一致,常量私有故此处钉值):
// 小格 48 + 间隔 8(_kGap=Tk.spaceSm,旧值 6 就近归档到 8)+ 条水平 padding 12。
// 改因(G1 交付自查):步距以 build 内实际渲染为准 = 48+8=56(原拟 54 有误)。
const double _kThumb = 48;
const double _kStride = 56;
const double _kEdgePad = 12;

/// G1/G2 假 assets API:thumbnailUrl 记录调用并即回假地址;downloadLink
/// 记录调用、结果可编排(403 注入测「保持缩略图+提示」)。
class _G2AssetsApi extends FakeAssetsApi {
  _G2AssetsApi(super.api);

  final downloadLinkCalls = <String>[];
  final thumbCalls = <String>[];

  /// 非 null 且为 Exception 时 download-link 抛错(后端 403 无下载权限)。
  Object? downloadLinkStaged;

  @override
  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async {
    downloadLinkCalls.add(assetId);
    final staged = downloadLinkStaged;
    if (staged is Exception) throw staged;
    return 'http://presigned/$assetId';
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) async {
    thumbCalls.add(assetId);
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }
}

class _G2FakeMsApi extends FakeMsApi {
  late final _assets = _G2AssetsApi(this);

  @override
  _G2AssetsApi get assets => _assets;
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
/// [linkStaged] 非 null 且为 Exception 时 download-link 抛错。
Future<_G2AssetsApi> _pumpPreview(WidgetTester tester, PreviewArgs args,
    {Object? linkStaged}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fake = installFakeApi(_G2FakeMsApi()) as _G2FakeMsApi;
  fake.assets.downloadLinkStaged = linkStaged;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      // 缩略图签名桩即回 → 胶片条小格落 TypeBlock,Ahem 字体 48px 格会假性
      // 溢出;缩字度量仅影响测试渲染(同 preview_swipe_test 口径)
      data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
      child: PreviewPage(args: args),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return fake.assets;
}

/// 胶片条里「当前张」小格(accent 高亮描边,区别于其余 white24)。
Finder _currentStripItem() => find.descendant(
      of: find.byType(Filmstrip),
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border?.top.color == Tk.accent),
    );

/// 胶片条横向滚动位置(Filmstrip 内 Scrollable 的 pixels;私有 controller
/// 不直取,按 preview_polish_test C1 口径读 ScrollableState)。
double _stripPixels(WidgetTester tester) {
  final scrollable = find
      .descendant(of: find.byType(Filmstrip), matching: find.byType(Scrollable))
      .first;
  return tester.state<ScrollableState>(scrollable).position.pixels;
}

ScrollPosition _stripPosition(WidgetTester tester) {
  final scrollable = find
      .descendant(of: find.byType(Filmstrip), matching: find.byType(Scrollable))
      .first;
  return tester.state<ScrollableState>(scrollable).position;
}

/// 第 [i] 张缩略图按布局常量推导的居中 offset(与 filmstrip.dart _follow
/// 同公式:条内中心 - 半视口,钳在滚动范围内)。
double _expectedCenterPixels(ScrollPosition pos, int i) {
  final left = _kEdgePad + i * _kStride;
  final center = left + _kThumb / 2;
  return (center - pos.viewportDimension / 2)
      .clamp(0.0, pos.maxScrollExtent)
      .toDouble();
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
  setUp(() => thumbnailCache.clear());

  // ── G1 胶片条恒居中跟随 ──────────────────────────────────────────────────
  testWidgets('G1:点选视口内贴边可见缩略图后,当前项滚至条中央(offset 断言)',
      (tester) async {
    final args = PreviewArgs(
      items: [for (var i = 1; i <= 60; i++) _img('g1-$i')],
      index: 0,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    expect(_stripPixels(tester), 0, reason: '前置:初始定位第 1 张,条在 0');

    // 第 17 张(index 16):视口内贴右缘、完整可见(条内区间 [908,956],
    // 视口 ~1080)——旧实现「已完整可见则不滚」恰好不打它
    const tapIndex = 16;
    await tester.tap(find.byType(ThumbnailImage).at(tapIndex));
    await tester.pump(); // onSelect → 页面 setState
    await tester.pump(const Duration(milliseconds: 400)); // 200ms animateTo
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('17 / 60'), findsOneWidget, reason: '前置:点选切张生效');

    final pos = _stripPosition(tester);
    expect(_stripPixels(tester), closeTo(_expectedCenterPixels(pos, tapIndex), 1.5),
        reason: 'G1:去掉守卫后当前张恒 animateTo 居中');

    // 几何复核:当前张中心与条视口中心几乎重合(行为级「居中」)
    final stripRect = tester.getRect(find.byType(Filmstrip));
    final itemRect = tester.getRect(_currentStripItem());
    expect((itemRect.center.dx - stripRect.center.dx).abs(), lessThan(3),
        reason: 'G1:当前张视觉居中(选中框恒在条中央)');
  });

  testWidgets('G1:横滑到屏外张后胶片条跟随居中(保留语义回归锚)', (tester) async {
    final args = PreviewArgs(
      items: [for (var i = 1; i <= 60; i++) _img('g1s-$i')],
      index: 16,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('17 / 60'), findsOneWidget, reason: '前置:定位 index 16');

    // 连续 4 次横滑到 index 20:逐张重居中语义下条随动(若跟随失效,当前张
    // 即漂出视口右缘——本用例即回归锚)
    for (var n = 0; n < 4; n++) {
      await tester.fling(find.byType(PreviewMedia), const Offset(-300, 0), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('21 / 60'), findsOneWidget, reason: '前置:横滑切到 index 20');

    // 屏外张跟随(旧实现亦滚;G1 后语义不变且恒居中)
    final pos = _stripPosition(tester);
    expect(_stripPixels(tester),
        closeTo(_expectedCenterPixels(pos, 20), 1.5),
        reason: 'G1:横滑到不可见张,条滚到当前张居中');
    final stripRect = tester.getRect(find.byType(Filmstrip));
    final itemRect = tester.getRect(_currentStripItem());
    expect((itemRect.center.dx - stripRect.center.dx).abs(), lessThan(3),
        reason: 'G1:屏外张视觉居中');
  });

  // ── G2 缩略图优先+放大换原图 ─────────────────────────────────────────────
  testWidgets('G2:进入预览仅请求 thumbnail-url,未签 download-link',
      (tester) async {
    final api = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('g2a')],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
    );
    expect(api.thumbCalls, contains('g2a'),
        reason: 'G2:进入即签缩略图(thumbnail-url)');
    expect(api.downloadLinkCalls, isEmpty,
        reason: 'G2:默认不签原图 download-link(放大超过 1.5x 才签)');
    expect(find.text('预览加载失败'), findsNothing, reason: '缩略图就绪非失败卡');
  });

  testWidgets('G2:双击放大后原图签发恰好一次;双击复位不重签', (tester) async {
    final api = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('g2b')],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
    );
    // G2 交付后:进预览只签缩略图,此断言同时锁「入口零签发」
    expect(api.downloadLinkCalls, isEmpty, reason: 'G2 前置:进预览未签原图');

    final center = tester.getCenter(find.byType(PreviewMedia));
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 400)); // 220ms 缩放动画
    await tester.pump();
    await tester.pump();
    expect(_mediaScale(tester), greaterThan(1.05),
        reason: '前置(既有 C3):双击放大到 2.5x(>1.5x 阈值)');

    expect(api.downloadLinkCalls, ['g2b'], reason: 'G2:放大触发原图签发恰好一次');

    // 已放大态再双击 = 复位,不回退原图、不重签
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: '前置:复位 1x');
    expect(api.downloadLinkCalls, ['g2b'], reason: 'G2:复位不再签发(仍一次)');
  });

  testWidgets('G2:放大签发 403 → 保持缩略图 + P7 式小字提示(非失败卡)',
      (tester) async {
    final api = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('g2c')],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
      linkStaged: ApiException(403, '无下载权限'),
    );
    expect(api.thumbCalls, contains('g2c'), reason: '前置:缩略图已签');
    // G2 交付后:进预览只看缩略图,尚无原图失败,提示不应出现
    expect(find.textContaining('原图不可用'), findsNothing);

    final center = tester.getCenter(find.byType(PreviewMedia));
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();
    expect(api.downloadLinkCalls, ['g2c'], reason: 'G2:放大签发原图(403)');

    // 403 保持缩略图 + P7 式不打断小字提示(复用既有降级文案)
    expect(find.textContaining('原图不可用'), findsOneWidget,
        reason: 'G2:原图签发失败保持缩略图并叠提示');
    expect(find.text('预览加载失败'), findsNothing,
        reason: 'G2:有缩略图不出失败卡');
    expect(api.thumbCalls.length, 1,
        reason: '缩略图经缓存去重,不因原图失败重签');
  });
}
