/// app-polish 验收用例(对应需求文档 2026-10-21-app-polish.md 包 C 各条):
/// - C1 胶片条自动跟随:进入/切到靠后张时胶片条滚动位置变化(filmstrip.dart);
/// - C2 沉浸模式:单击媒体顶栏/信息条隐、再击恢复(preview_page.dart);
/// - C3 双击缩放:双击后 InteractiveViewer scale>1、再双击复位(preview_media.dart);
/// - C5 下载入队就地反馈:点「下载」后按钮就地变为「已入队」类状态
///   (preview_page.dart,不再只有 SnackBar 浮出)。
/// app-polish-2 增补(G 包,对应 2026-10-22-app-polish-2.md):
/// - G1 胶片条恒居中:点选视口贴边项/横滑切张(含相邻已可见张)后当前张
///   一律 animateTo 居中(去「已完整可见则不滚」守卫);
/// - G2(W4/W6 改写,app-thumbnail-storm-fix 2026-10-26):缩略图优先改为
///   W6 数据源——进入磁盘 miss 经 fetchThumb 签一次 thumbnail-url 取字节,
///   Image.memory 直出;放大(双击)恒显缩略图、零新增 dio 调用(W4:原图
///   升级链路整体删除),复位正常;403 桩在场恒零调用,图片场景永不出现
///   「原图不可用」提示(只剩视频 inline 失败回退分支)。
///
/// 套路:同 preview_page_swipe_test.dart——内存假 API,网络图在测试区恒
/// errorBuilder,不影响手势与结构断言;全程逐 pump(缩略图 spinner 不定长,
/// pumpAndSettle 会挂)。页面级用例文本度量缩至 0.5(C3 改因:G2 起无缩略图
/// 资产入口走原图 inline,胶片条小格落 TypeBlock,Ahem 字体 48px 格需缩字防溢出)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show ThumbnailImage, thumbnailCache;
import 'package:ms_app/features/preview/filmstrip.dart';
import 'package:ms_app/features/preview/preview_chrome.dart';
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
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async {
    final t = linkThrows;
    if (t is Exception) throw t;
    return 'http://presigned/$assetId';
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) => Completer<({String url, int expiresIn})>().future;
}

class _PreviewFakeMsApi extends FakeMsApi {
  _PreviewFakeMsApi(Object? linkThrows) : _linkThrows = linkThrows;

  final Object? _linkThrows;

  late final _assets2 = _PreviewAssetsApi(this, linkThrows: _linkThrows);

  @override
  _PreviewAssetsApi get assets => _assets2;
}

/// W4/W6(G2 改写):记录式假 API——thumbnail-url 即回假签名(fetchThumb
/// 链签名桩),download-link 记录入参(asAttachment 口径)且可编排抛错
/// (403 桩在场恒零调用用例)。
class _G2AssetsApi extends FakeAssetsApi {
  _G2AssetsApi(super.api);

  final thumbCalls = <String>[];
  final linkCalls = <({String id, bool asAttachment})>[];
  Object? linkStaged;

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) async {
    thumbCalls.add(assetId);
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }

  @override
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async {
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

/// W4/W6 假 HttpClient:任何请求都回 200 + 1x1 PNG 字节(fetchThumb 字节下载
/// 桩;桩风格对齐 preview_fallback_thumb_test——noSuchMethod 返回 null)。
/// T12 配方:HttpOverrides.runZoned 包住整个测试体(pumpMedia+轮询都在 zone
/// 内),静态 _thumbHttp 首建(本文件首个 fetch,即首个 W6 用例)即被拦;桩
/// 无状态,后续用例复用同实例不受 zone 影响。
class _PngHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _PngRequest();
  @override
  set connectionTimeout(Duration? _) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _PngRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _PngResponse();
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _PngResponse implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([kPng1x1]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 1×1 透明 PNG(经典字节,测试内可真实解码出帧)。
final Uint8List kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Asset _img(
  String id, {
  Map<String, dynamic> tags = const {'thumbnail_key': 'k'},
}) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 4,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  tags: tags,
);

/// 挂预览页并落定首轮 loading(逐 pump,不用 pumpAndSettle)。
Future<void> _pumpPreview(
  WidgetTester tester,
  PreviewArgs args, {
  Object? linkThrows,
}) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  installFakeApi(_PreviewFakeMsApi(linkThrows));
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        // C3 改因(G2):无缩略图资产胶片条小格落 TypeBlock,Ahem 字体需缩字防溢出
        data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
        child: PreviewPage(args: args),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// 挂裸 PreviewMedia(W4/W6 媒体状态机用,无胶片条无溢出噪音)并等首图落地:
/// fetchThumb(签名→假 HttpClient 字节→解码)链跨多拍微任务,逐 pump 轮询
/// 等 InteractiveViewer 出现(加载圈为不定长动画,pumpAndSettle 不可用)。
Future<_G2AssetsApi> _pumpMedia(
  WidgetTester tester,
  Asset asset, {
  Object? linkStaged,
}) async {
  final fake = installFakeApi(_G2FakeMsApi()) as _G2FakeMsApi;
  fake.assets.linkStaged = linkStaged;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(child: PreviewMedia(asset: asset)),
      ),
    ),
  );
  for (var i = 0; i < 40; i++) {
    if (find.byType(InteractiveViewer).evaluate().isNotEmpty) break;
    await tester.pump(const Duration(milliseconds: 50));
  }
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

void main() {
  setUp(() => thumbnailCache.clear());

  // ── C1 胶片条自动跟随 ───────────────────────────────────────────────────
  testWidgets('C1:初始定位靠后张/横滑切张后,胶片条滚动位置跟随变化', (tester) async {
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
    expect(
      _stripPixels(tester),
      greaterThan(0),
      reason: 'C1:进入靠后张,胶片条应自动滚动让当前张可见',
    );

    // 横滑切到下一张,跟随保持
    await tester.fling(find.byType(PreviewMedia), const Offset(-300, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('42 / 60'), findsOneWidget, reason: '前置:横滑切张生效');
    expect(_stripPixels(tester), greaterThan(0), reason: 'C1:切张后胶片条跟随(仍指向当前张)');
  });

  // ── G1 胶片条恒居中 ─────────────────────────────────────────────────────
  testWidgets('G1:点选视口贴边(已完整可见)项后,该项滚至条中央', (tester) async {
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

    // 步距=48+8(Tk.spaceSm)、条内 padding 8、浮层留边 12:第 19 格(i=18)
    // 中心 1040(视口 1056)。点选后恒居中:target=1040-528=512。
    final cell = find.byType(ThumbnailImage).at(18);
    await tester.tap(cell);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('19 / 60'), findsOneWidget, reason: '前置:点选切张生效');
    expect(
      _stripPixels(tester),
      closeTo(512, 8),
      reason: 'G1:贴边可见项点选后恒居中(旧守卫保持 0 不滚)',
    );
    // 几何复核走「当前张高亮格」(previewGold 描边唯一):.at(N) 在滚动后
    // ListView 逐出头格时会漂移,不能复用作居中锚。
    final selected = find.descendant(
      of: find.byType(Filmstrip),
      matching: find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border?.top.color == Tk.previewGold,
      ),
    );
    expect(
      tester.getCenter(selected).dx,
      closeTo(540, 8),
      reason: 'G1:被点项停在胶片条视口中央',
    );
  });

  testWidgets('G1:横滑切到相邻(仍可见)张后也重居中,不再「可见即不动」', (tester) async {
    // 进入第 41 张:jumpTo 居中 target=8+40×56+24-528=1744;横滑到第 42 张
    // (旧守卫:第 42 格在视口内完整可见→不滚;新口径:恒 animateTo 1800)。
    final args = PreviewArgs(
      items: [for (var i = 1; i <= 60; i++) _img('g1b-$i')],
      index: 40,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_stripPixels(tester), closeTo(1744, 8), reason: '前置:41 张已居中');

    await tester.fling(find.byType(PreviewMedia), const Offset(-300, 0), 1200);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('42 / 60'), findsOneWidget, reason: '前置:横滑切张生效');
    expect(
      _stripPixels(tester),
      closeTo(1800, 8),
      reason: 'G1:横滑切张后当前张恒居中(旧守卫会停在 1744 不动)',
    );
  });

  // ── C2 沉浸模式 ─────────────────────────────────────────────────────────
  testWidgets('C2:单击媒体进入沉浸(顶栏/胶片条 offstage),再单击恢复', (tester) async {
    final args = PreviewArgs(
      items: [_img('c2-1'), _img('c2-2'), _img('c2-3')],
      index: 0,
      folderId: 'f1',
      canDownload: true,
    );
    await _pumpPreview(tester, args);
    expect(find.byType(PreviewTopBar), findsOneWidget);
    expect(find.byType(Filmstrip), findsOneWidget, reason: '前置:多文件有胶片条');

    await tester.tap(find.byType(PreviewMedia));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // 验收口径=「chrome offstage」:实现用 Offstage(find 默认 skipOffstage)。
    expect(find.byType(PreviewTopBar), findsNothing, reason: 'C2:沉浸态顶栏隐去');
    expect(find.byType(Filmstrip), findsNothing, reason: 'C2:沉浸态胶片条隐去');
    expect(find.text('1 / 3'), findsNothing, reason: 'C2:顶部计数随顶栏隐去');

    // 再单击恢复
    await tester.tap(find.byType(PreviewMedia));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PreviewTopBar), findsOneWidget, reason: 'C2:再单击恢复顶栏');
    expect(find.byType(Filmstrip), findsOneWidget, reason: 'C2:再单击恢复胶片条');
  });

  // ── C3 双击缩放 ─────────────────────────────────────────────────────────
  testWidgets('C3:双击图片 scale 升到 >1(规格 2.5x),再双击复位 1x', (tester) async {
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
    expect(
      _mediaScale(tester),
      greaterThan(1.05),
      reason: 'C3:双击放大(目标 2.5x,仅断言 >1 不钉具体动画实现)',
    );

    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: 'C3:再双击复位 1x');
  });

  // ── C5 下载入队就地反馈 ─────────────────────────────────────────────────
  testWidgets('C5:点「下载」入队后按钮就地变为「已入队」类状态', (tester) async {
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
    expect(
      find.textContaining('已入队'),
      findsWidgets,
      reason: 'C5:下载钮就地状态变化(入队中→已入队 ✓)',
    );
    // 收尾:排空已入队复原 Timer 与队列 worker 计时器。改因(app-polish C5
    // 交付):本用例 downloadLink 恒 403→缩略图桩件永挂起,媒体区加载圈为
    // 不定长动画,pumpAndSettle 必挂(与 _pumpPreview 注释同源),改逐 pump 排空。
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
  });

  // ── G2→W4/W6:缩略图数据源与放大行为(app-thumbnail-storm-fix 改写)──────
  testWidgets(
    'W6:进入预览磁盘 miss → fetchThumb 签一次 thumbnail-url 取字节,Image.memory 直出不签原图',
    (tester) async {
      await HttpOverrides.runZoned(() async {
        // 本文件无磁盘挂载(setUp 不 attach 目录):ThumbDiskStore._dir 为 null,
        // read 恒 miss → fetchThumb(签名→假 HttpClient 字节)→ Image.memory。
        final fake = await _pumpMedia(tester, _img('g2a-1'));

        expect(fake.thumbCalls, [
          'g2a-1',
        ], reason: 'W6:磁盘 miss 经 fetchThumb 签一次 thumbnail-url');
        expect(fake.linkCalls, isEmpty, reason: 'W6:入口不签 download-link 原图');
        expect(
          find.byType(InteractiveViewer),
          findsOneWidget,
          reason: '缩略图直显仍为图片分支(可放大)',
        );
        expect(
          find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
          findsOneWidget,
          reason: 'W6:直出来源为 Image.memory(fetchThumb 字节),缩略图路径 NetworkImage 退场',
        );
        expect(
          find.textContaining('原图不可用'),
          findsNothing,
          reason: '缩略图正常直显,无回退提示',
        );
        expect(find.text('预览加载失败'), findsNothing);
      }, createHttpClient: (_) => _PngHttpClient());
    },
  );

  testWidgets('W4:双击放大恒显缩略图,零新增 dio 调用;复位正常(原 G2 放大/P2-1 回退用例改写)', (
    tester,
  ) async {
    await HttpOverrides.runZoned(() async {
      final fake = await _pumpMedia(tester, _img('g2b-1'));
      final center = tester.getCenter(find.byType(PreviewMedia));
      expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: '前置:初始 1x');

      await _doubleTap(tester, center); // 2.5x,缩放动画 220ms
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _mediaScale(tester),
        greaterThan(1.05),
        reason: 'W4:双击放大仍生效(只动变换矩阵,防「图未渲染假绿」)',
      );
      expect(fake.linkCalls, isEmpty, reason: 'W4:放大零新增 dio 调用(原图升级链路整体删除)');
      expect(fake.thumbCalls, ['g2b-1'], reason: 'W4:缩略图签名仍只有入口那一次');
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsOneWidget,
        reason: 'W4:放大后画面恒为 Image.memory 缩略图',
      );

      await _doubleTap(tester, center); // 复位 1x
      await tester.pump(const Duration(milliseconds: 400));
      expect(_mediaScale(tester), closeTo(1.0, 0.05), reason: 'W4:再双击复位 1x');
      expect(fake.linkCalls, isEmpty, reason: 'W4:复位同样零原图签发');
      expect(fake.thumbCalls, ['g2b-1'], reason: 'W4:复位不触发重签');
    }, createHttpClient: (_) => _PngHttpClient());
  });

  testWidgets('W4:放大不触发原图签发(403 桩在场零调用),恒显缩略图(原 G2 403 回退用例改写)', (
    tester,
  ) async {
    await HttpOverrides.runZoned(() async {
      // linkStaged 403 保留注入以证明零调用:若放大仍会签原图,此处即抛 403 异常。
      final fake = await _pumpMedia(
        tester,
        _img('g2c-1'),
        linkStaged: ApiException(403, '无下载权限'),
      );
      final center = tester.getCenter(find.byType(PreviewMedia));

      await _doubleTap(tester, center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.linkCalls, isEmpty, reason: 'W4:403 桩在场仍零调用——放大不再签原图');
      expect(_mediaScale(tester), greaterThan(1.05), reason: 'W4:双击放大缩放生效');
      expect(fake.thumbCalls, ['g2c-1'], reason: 'W4:缩略图仅入口一次签名');
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsOneWidget,
        reason: 'W4:恒显 Image.memory 缩略图',
      );
      expect(
        find.textContaining('原图不可用'),
        findsNothing,
        reason: 'W4:图片放大场景永不出现回退提示(只剩视频 inline 失败回退分支)',
      );
      expect(find.text('预览加载失败'), findsNothing, reason: 'W4:零调用即无失败卡');
    }, createHttpClient: (_) => _PngHttpClient());
  });

  // ── P2-8 入队计时器按资产独立 ────────────────────────────────────────────
  testWidgets('P2-8:2 秒内连下 A/B,各自计时;2.1s 后两者都复位', (tester) async {
    final args = PreviewArgs(
      items: [_img('p8-a'), _img('p8-b')],
      index: 0,
      folderId: 'f1',
      canDownload: true,
      where: '项目A/夹B',
    );
    // worker 立即终态(403),避免悬挂任务/IO
    await _pumpPreview(tester, args, linkThrows: ApiException(403, '无下载权限'));

    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(find.text('已入队 ✓'), findsOneWidget, reason: 'A 入队');

    // 切到 B(2s 窗口内)并下载
    await tester.tap(find.byType(ThumbnailImage).at(1));
    await tester.pump();
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget, reason: '前置:切到 B');
    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(find.text('已入队 ✓'), findsOneWidget, reason: 'B 入队');

    // 2.1s:两个计时器都到期,B 复位(旧实现会取消 A 的计时并让 A 永挂)
    await tester.pump(const Duration(milliseconds: 2100));
    expect(find.text('已入队 ✓'), findsNothing, reason: 'B 已复位');

    await tester.tap(find.byType(ThumbnailImage).at(0));
    await tester.pump();
    await tester.pump();
    expect(find.text('1 / 2'), findsOneWidget, reason: '前置:切回 A');
    expect(
      find.text('已入队 ✓'),
      findsNothing,
      reason: 'P2-8:A 的复位计时未被 B 取消,按钮恢复可点',
    );
    expect(find.text('下载'), findsOneWidget);
    // 收尾:排空队列 worker 计时器(与 C5 同口径)
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
  });
}
