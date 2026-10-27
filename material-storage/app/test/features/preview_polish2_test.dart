/// app-polish-2(P2 批)预览包验收用例(对应需求文档 2026-10-22-app-polish-2.md;
/// G2 段经 app-thumbnail-storm-fix W4/W6 改写,2026-10-26):
/// - G1(#2) 胶片条恒居中跟随:去掉「已完整可见则不滚」守卫——点选视口内
///   贴边可见项后该项滚至条中央(offset 断言);横滑到屏外张后跟随(保留语义);
/// - W6(#23-#26,原 G2「进入仅请求 thumbnail-url」改写):预写磁盘字节进
///   预览 → Image.memory 直出,thumbnail-url/download-link 全零调用、无失败卡;
/// - W4(#19-#21,原 G2「放大换原图/403 回退」链路整体删除):双击放大只动
///   缩放矩阵(scale>1.05),零新增 dio 调用;复位回 1x 仍零调用;403 桩在场
///   也零调用、恒显缩略图、无「原图不可用」提示与失败卡。
///
/// 套路:同 preview_polish_test.dart——内存假 API(thumbnailUrl/downloadLink
/// 均记录调用);胶片条小格网络段在测试区恒降级色块,不影响手势与 API 记录
/// 断言。字节源按 T12 配方磁盘预写:setUp 挂临时目录(debugAttachDirectory),
/// tearDown 删目录并复位单例;ThumbDiskStore 已同步 IO 化,测试体内直接
/// await write 预写即可。磁盘命中链跨多拍,统一小轮询 pump(加载圈为不定长
/// 动画,勿 pumpAndSettle)。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_disk_store.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show ThumbnailImage, thumbnailCache;
import 'package:ms_app/features/preview/filmstrip.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tokens.dart';

import '../helpers/api_harness.dart';

// filmstrip.dart 布局常量同源(与 build 段保持一致,常量私有故此处钉值):
// 小格 48 + 间隔 8(_kGap=Tk.spaceSm)+ 条内水平 padding 8;浮层卡另有页面
// 留边 12(只影响滚动视口宽度,公式里用 viewportDimension 自适应)。
const double _kThumb = 48;
const double _kStride = 56;
const double _kEdgePad = 8;

/// 1×1 透明 PNG(经典字节,磁盘预写后可真实解码出帧)。
final Uint8List _kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// G1/W4/W6 假 assets API:thumbnailUrl/downloadLink 均只记录调用(W6 断言
/// 磁盘命中零签名、W4 断言放大零原图签发);downloadLink 结果可编排(403
/// 桩在场,验证放大时依旧零调用)。
class _G2AssetsApi extends FakeAssetsApi {
  _G2AssetsApi(super.api);

  final downloadLinkCalls = <String>[];
  final thumbCalls = <String>[];

  /// 非 null 且为 Exception 时 download-link 抛错(后端 403 无下载权限)。
  Object? downloadLinkStaged;

  @override
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async {
    downloadLinkCalls.add(assetId);
    final staged = downloadLinkStaged;
    if (staged is Exception) throw staged;
    return 'http://presigned/$assetId';
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) async {
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
Future<_G2AssetsApi> _pumpPreview(
  WidgetTester tester,
  PreviewArgs args, {
  Object? linkStaged,
}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final fake = installFakeApi(_G2FakeMsApi()) as _G2FakeMsApi;
  fake.assets.downloadLinkStaged = linkStaged;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        // 缩略图签名桩即回 → 胶片条小格落 TypeBlock,Ahem 字体 48px 格会假性
        // 溢出;缩字度量仅影响测试渲染(同 preview_swipe_test 口径)
        data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
        child: PreviewPage(args: args),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return fake.assets;
}

/// 小轮询推进假时钟直到 [ready](磁盘命中/缩略图链跨多拍微任务调度,
/// pumpAndSettle 一轮不可达;加载圈为不定长动画,勿 pumpAndSettle)。
Future<void> _pollUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 10; i++) {
    if (ready()) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 胶片条里「当前张」小格(previewGold 高亮描边,区别于其余 previewLine)。
Finder _currentStripItem() => find.descendant(
  of: find.byType(Filmstrip),
  matching: find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).border?.top.color == Tk.previewGold,
  ),
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
  late Directory dir;

  setUp(() {
    thumbnailCache.clear();
    // T12 配方:磁盘预写夹具(临时目录挂单例)。G1 用例磁盘 miss 与旧
    // _dir null 同为 miss,行为不变;W4/W6 用例经 write 预写字节走命中路径。
    dir = Directory.systemTemp.createTempSync('preview_polish2');
    ThumbDiskStore.I.debugAttachDirectory(dir);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    ThumbDiskStore.I.debugAttachDirectory(null); // 单例全局,必须复位
  });

  // ── G1 胶片条恒居中跟随 ──────────────────────────────────────────────────
  testWidgets('G1:点选视口内贴边可见缩略图后,当前项滚至条中央(offset 断言)', (tester) async {
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
    expect(
      _stripPixels(tester),
      closeTo(_expectedCenterPixels(pos, tapIndex), 1.5),
      reason: 'G1:去掉守卫后当前张恒 animateTo 居中',
    );

    // 几何复核:当前张中心与条视口中心几乎重合(行为级「居中」)
    final stripRect = tester.getRect(find.byType(Filmstrip));
    final itemRect = tester.getRect(_currentStripItem());
    expect(
      (itemRect.center.dx - stripRect.center.dx).abs(),
      lessThan(3),
      reason: 'G1:当前张视觉居中(选中框恒在条中央)',
    );
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
      await tester.fling(
        find.byType(PreviewMedia),
        const Offset(-300, 0),
        1200,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.text('21 / 60'), findsOneWidget, reason: '前置:横滑切到 index 20');

    // 屏外张跟随(旧实现亦滚;G1 后语义不变且恒居中)
    final pos = _stripPosition(tester);
    expect(
      _stripPixels(tester),
      closeTo(_expectedCenterPixels(pos, 20), 1.5),
      reason: 'G1:横滑到不可见张,条滚到当前张居中',
    );
    final stripRect = tester.getRect(find.byType(Filmstrip));
    final itemRect = tester.getRect(_currentStripItem());
    expect(
      (itemRect.center.dx - stripRect.center.dx).abs(),
      lessThan(3),
      reason: 'G1:屏外张视觉居中',
    );
  });

  // ── W6 磁盘命中直出 / W4 放大恒缩略图(原 G2 段改写)────────────────────
  testWidgets('W6:进入预览磁盘命中零签名零原图,Image.memory 直出', (tester) async {
    // ThumbDiskStore 已同步 IO 化:测试体内直接预写,不再需要 runAsync
    await ThumbDiskStore.I.write('g2a', _kPng1x1);
    final api = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('g2a')],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
    );
    await _pollUntil(
      tester,
      () => find
          .byWidgetPredicate((w) => w is Image && w.image is MemoryImage)
          .evaluate()
          .isNotEmpty,
    );
    expect(
      api.thumbCalls,
      isEmpty,
      reason: 'W6:磁盘命中零签名(不再进预览即签 thumbnail-url)',
    );
    expect(
      api.downloadLinkCalls,
      isEmpty,
      reason: 'W6:磁盘命中零原图签发(download-link 恒不触发)',
    );
    // 胶片条小格命中时也走同一磁盘字节,故用「至少一个」口径(勿钉死数量)
    expect(
      find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
      findsWidgets,
      reason: 'W6:主图 Image.memory 直出(磁盘位图上屏,零网络)',
    );
    expect(find.text('预览加载失败'), findsNothing, reason: '磁盘命中非失败卡');
  });

  testWidgets('W4:双击放大零新增原图签发;缩放生效;复位正常', (tester) async {
    await ThumbDiskStore.I.write('g2b', _kPng1x1);
    final api = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('g2b')],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
    );
    // 磁盘命中直出后图片分支才挂载 InteractiveViewer(轮询出图)
    await _pollUntil(
      tester,
      () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
    );
    expect(
      find.byType(InteractiveViewer),
      findsOneWidget,
      reason: '前置:磁盘命中直出图片分支',
    );
    expect(api.downloadLinkCalls, isEmpty, reason: 'W4 前置:进预览(磁盘命中)未签原图');

    final center = tester.getCenter(find.byType(PreviewMedia));
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 400)); // 220ms 缩放动画
    await tester.pump();
    await tester.pump();
    expect(
      _mediaScale(tester),
      greaterThan(1.05),
      reason: 'W4:双击放大缩放生效(只动变换矩阵至 2.5x)',
    );
    expect(
      api.downloadLinkCalls,
      isEmpty,
      reason: 'W4:放大零新增原图签发(自动换原图链路已删,防图未渲染假绿)',
    );

    // 已放大态再双击 = 复位,同样零 dio 调用
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: 'W4:复位回 1x');
    expect(api.downloadLinkCalls, isEmpty, reason: 'W4:复位仍零原图签发(全程零 dio 调用)');
  });

  testWidgets('W4:放大不触发原图签发(403 桩在场零调用),恒显缩略图', (tester) async {
    await ThumbDiskStore.I.write('g2c', _kPng1x1);
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
    // 磁盘命中直出后图片分支才挂载 InteractiveViewer(轮询出图)
    await _pollUntil(
      tester,
      () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
    );
    expect(
      find.byType(InteractiveViewer),
      findsOneWidget,
      reason: '前置:磁盘命中直出图片分支',
    );

    final center = tester.getCenter(find.byType(PreviewMedia));
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 400)); // 220ms 缩放动画
    await tester.pump();
    await tester.pump();
    expect(
      _mediaScale(tester),
      greaterThan(1.05),
      reason: 'W4:放大缩放生效(恒显缩略图不换源)',
    );
    expect(api.downloadLinkCalls, isEmpty, reason: 'W4:403 桩在场仍零调用(放大不签原图)');
    expect(
      find.textContaining('原图不可用'),
      findsNothing,
      reason: 'W4:无原图签发即无回退提示(P7 提示失去触发点)',
    );
    expect(find.text('预览加载失败'), findsNothing, reason: 'W4:磁盘命中无失败卡');
    expect(api.thumbCalls, isEmpty, reason: 'W4:磁盘命中恒显缩略图(零签名)');
  });
}
