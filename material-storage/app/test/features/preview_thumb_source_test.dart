/// T13 预览缩略图数据源集中用例(app-thumbnail-storm-fix W6 #23-#26):
/// 磁盘命中(image/heic/livp)零网络直出;miss 经 fetchThumb 共享任务(同页
/// 同 asset 不重复签名/下载)并落盘;冷缓存 livp 的 livePreviewUrl 并行不被
/// 阻塞、20s 总上限落失败卡;晚到 live URL 经 setState 出「播放实况」;损坏
/// 字节删坏文件落失败卡;签名悬挂 20s 超时;收到 null 仍 mounted 置失败卡;
/// read 期间 dispose 不发 fetch;写盘前 clear 则旧代 write 被代数丢弃;退出
/// 预览 dispose 句柄取消无 pending timer。
/// 配方(执行状态 §四·6):ThumbDiskStore 全同步 IO 可直接 await;桩 HttpClient
/// 须在同文件首个 fetch 前经 HttpOverrides.runZoned 装(静态 _thumbHttp 首建
/// 绑 zone;磁盘命中用例不触发 fetch 不受影响);管线/闸/下载链轮询 pump 推进;
/// 引擎解码回调走真实事件循环,经 tester.runAsync 给真实时间窗口。全局
/// tearDown 已有 reset+clear,用例内注入的读/写闸自行清。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_disk_store.dart';
import 'package:ms_app/core/thumb_pipeline.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show thumbnailCache;
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

// ── 桩 HttpClient(fetchThumb 字节下载;风格对齐 preview_fallback_thumb_test)──

/// 桩请求已命中的 URL(setUp 清空;断言下载次数/目标用)。
final _stubUrls = <Uri>[];

class _PngHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _stubUrls.add(url);
    return _PngRequest();
  }

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

// ── 假 API:thumbnailUrl / livePreviewUrl 记录 + 可编排悬挂 ──────────────────

class _T13AssetsApi extends FakeAssetsApi {
  _T13AssetsApi(super.api);

  final thumbCalls = <String>[];
  final liveCalls = <String>[];

  /// 非 null 时签名挂起(超时/取消/clear 用例)。
  Completer<({String url, int expiresIn})>? signHang;

  /// 非 null 时 livePreviewUrl 挂起(晚到 live URL 用例)。
  Completer<({String url, int expiresIn})>? liveHang;

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) async {
    thumbCalls.add(assetId);
    final hang = signHang;
    if (hang != null) return hang.future;
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }

  @override
  Future<({String url, int expiresIn})> livePreviewUrl(String assetId) async {
    liveCalls.add(assetId);
    final hang = liveHang;
    if (hang != null) return hang.future;
    return (url: 'http://live.test/$assetId', expiresIn: 1800);
  }
}

class _T13MsApi extends FakeMsApi {
  late final _assets = _T13AssetsApi(this);

  @override
  _T13AssetsApi get assets => _assets;
}

// ── 夹具 ─────────────────────────────────────────────────────────────────────

/// 1×1 透明 PNG(经典字节,测试内可真实解码出帧)。
final Uint8List kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// 带缩略图 key 的资产(heic/livp 按扩展名判 kind,见 detectKind)。
Asset _asset(String id, {String ext = 'jpg', String? ct = 'image/jpeg'}) =>
    Asset(
      id: id,
      filename: '$id.$ext',
      sizeBytes: 4,
      contentType: ct,
      createdAt: '2026-10-20T10:00:00Z',
      tags: const {'thumbnail_key': 'k'},
    );

Finder get _memoryImage =>
    find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage);

/// 装配假 API(先 stage 编排后 pump)并挂 PreviewMedia;返回带计数的假 assets。
Future<_T13AssetsApi> _pumpMedia(
  WidgetTester tester,
  Asset asset, {
  void Function(_T13AssetsApi api)? stage,
}) async {
  final api = (installFakeApi(_T13MsApi()) as _T13MsApi).assets;
  addTearDown(() => session.api = null);
  stage?.call(api);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(child: PreviewMedia(asset: asset)),
      ),
    ),
  );
  return api;
}

/// 轮询推进假时钟直至条件成立(管线/闸/下载链跨多拍微任务,pumpAndSettle 不可达)。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() cond, {
  int max = 40,
  String reason = '条件未在轮询窗口内达成',
}) async {
  for (var i = 0; i < max; i++) {
    if (cond()) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(cond(), isTrue, reason: reason);
}

/// 轮询等待落盘(debugHas 同步探测;写盘 fire-and-forget 链经 pump 推进)。
Future<void> _waitForWritten(WidgetTester tester, String assetId) async {
  for (var i = 0; i < 100; i++) {
    if (ThumbDiskStore.I.debugHas(assetId)) return;
    await tester.pump(const Duration(milliseconds: 50));
    await ThumbDiskStore.I.read(assetId); // 真实让出一拍催化(同步化后保配方)
  }
  expect(
    ThumbDiskStore.I.debugHas(assetId),
    isTrue,
    reason: '写盘应在 pump 轮询窗口内落地',
  );
}

void main() {
  late Directory dir;

  setUp(() {
    thumbnailCache.clear();
    _stubUrls.clear();
    dir = Directory.systemTemp.createTempSync('pts_thumb');
    ThumbDiskStore.I.debugAttachDirectory(dir);
  });

  tearDown(() {
    // 注入的读/写闸必须自己清(单例全局防跨用例挂起);目录卸载重挂默认。
    ThumbDiskStore.I.debugSetReadGate(null);
    ThumbDiskStore.I.debugSetWriteGate(null);
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    ThumbDiskStore.I.debugAttachDirectory(null);
  });

  testWidgets('T13-1 磁盘命中(image):零签名零下载,Image.memory 直出', (tester) async {
    await ThumbDiskStore.I.write('t13-img', kPng1x1);
    final api = await _pumpMedia(tester, _asset('t13-img'));
    await _pumpUntil(tester, () => _memoryImage.evaluate().isNotEmpty, max: 10);

    expect(api.thumbCalls, isEmpty, reason: 'W6 #23:磁盘命中不签 thumbnail-url');
    expect(_stubUrls, isEmpty, reason: '磁盘命中零字节下载');
    expect(_memoryImage, findsOneWidget, reason: '缩略图字节直出(Image.memory)');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('T13-2 磁盘命中(heic):同口径零签名零下载直出', (tester) async {
    await ThumbDiskStore.I.write('t13-heic', kPng1x1);
    final api = await _pumpMedia(
      tester,
      _asset('t13-heic', ext: 'heic', ct: 'image/heic'),
    );
    await _pumpUntil(tester, () => _memoryImage.evaluate().isNotEmpty, max: 10);

    expect(api.thumbCalls, isEmpty, reason: 'heic 分支同走 _loadThumb,磁盘命中零签名');
    expect(_stubUrls, isEmpty);
    expect(_memoryImage, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('T13-3 磁盘命中(livp):零缩略图网络,livePreviewUrl 恰好 1 次', (tester) async {
    await ThumbDiskStore.I.write('t13-livp', kPng1x1);
    final api = await _pumpMedia(
      tester,
      _asset('t13-livp', ext: 'livp', ct: null),
    );
    await _pumpUntil(tester, () => _memoryImage.evaluate().isNotEmpty, max: 10);
    await tester.pump(); // live URL 微任务落 setState

    expect(api.thumbCalls, isEmpty, reason: '磁盘命中零缩略图签名');
    expect(_stubUrls, isEmpty, reason: '磁盘命中零字节下载');
    expect(api.liveCalls, [
      't13-livp',
    ], reason: 'livePreviewUrl 恰好 1 次(W4 #21)');
    expect(find.text('播放实况'), findsOneWidget, reason: 'live URL 已到出回切按钮');
    expect(_memoryImage, findsOneWidget);
  });

  testWidgets('T13-4 冷缓存 livp(签名悬挂):live URL 不被阻塞,≤20s 落失败卡', (tester) async {
    final api = await _pumpMedia(
      tester,
      _asset('t13-cold', ext: 'livp', ct: null),
      stage: (a) {
        a.signHang = Completer();
      },
    );
    // live 并行发起:数百 ms 内已发出(不被悬挂的缩略图签名阻塞)
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.liveCalls, ['t13-cold'], reason: 'W4 #21:livePreviewUrl 并行发起');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 19));
    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: '19s < 20s UI 总上限,仍在等待(非提前失败)',
    );

    await tester.pump(const Duration(seconds: 3));
    expect(
      find.text('预览图还在生成,请稍后刷新重试'),
      findsOneWidget,
      reason: '总时长 ≤20s 落定失败卡(thumbFailText 口径),非永久 loading',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('T13-5 晚到 live URL:setState 生效,「播放实况」按钮出现', (tester) async {
    await ThumbDiskStore.I.write('t13-late', kPng1x1);
    final api = await _pumpMedia(
      tester,
      _asset('t13-late', ext: 'livp', ct: null),
      stage: (a) {
        a.liveHang = Completer();
      },
    );
    await _pumpUntil(tester, () => _memoryImage.evaluate().isNotEmpty, max: 10);
    expect(find.text('播放实况'), findsNothing, reason: '前置:live URL 未到无按钮');

    api.liveHang!.complete((url: 'http://live.test/t13-late', expiresIn: 1800));
    await tester.pump();
    expect(
      find.text('播放实况'),
      findsOneWidget,
      reason: 'W4 #21:晚到 live URL 经 setState 刷新出回切按钮',
    );
  });

  testWidgets('T13-6 磁盘 miss → fetchThumb:同页同 asset 仅 1 签名 1 下载并落盘', (
    tester,
  ) async {
    await HttpOverrides.runZoned(() async {
      final api = (installFakeApi(_T13MsApi()) as _T13MsApi).assets;
      addTearDown(() => session.api = null);
      // 同页挂两处同 asset 预览:共享 fetchThumb 任务,不重复签名/下载
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: PreviewMedia(asset: _asset('t13-miss'))),
                Expanded(child: PreviewMedia(asset: _asset('t13-miss'))),
              ],
            ),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => tester.widgetList(_memoryImage).length == 2,
        reason: '两处预览均直出(fetchThumb 共享字节)',
      );

      expect(api.thumbCalls, ['t13-miss'], reason: '同 asset 共享任务:仅 1 次签名');
      expect(_stubUrls.map((u) => u.toString()), [
        'http://thumb.test/t13-miss',
      ], reason: '同页同 asset 仅 1 次字节下载(订阅去重)');
      await _waitForWritten(tester, 't13-miss');
      expect(
        await ThumbDiskStore.I.read('t13-miss'),
        kPng1x1,
        reason: '成功字节按捕获代数落盘(下次进入磁盘直出)',
      );
    }, createHttpClient: (_) => _PngHttpClient());
  });

  testWidgets('T13-7 损坏字节:解码失败删坏文件并落「图片解码失败」失败卡', (tester) async {
    await ThumbDiskStore.I.write(
      't13-bad',
      Uint8List.fromList(List.filled(64, 0x7F)),
    );
    final api = await _pumpMedia(tester, _asset('t13-bad'));
    expect(api.thumbCalls, isEmpty, reason: '前置:磁盘命中零签名');

    await tester.pump(); // Image.memory 挂载,引擎开始解码
    // 引擎解码回调走真实事件循环:runAsync 提供真实时间窗口让失败送达
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    // errorBuilder 同步 remove 坏字节(W6 #25);轮询到文件消失
    await _pumpUntil(
      tester,
      () => !ThumbDiskStore.I.debugHas('t13-bad'),
      max: 20,
      reason: 'W6 #25:解码失败已 remove 目录中坏字节',
    );
    await tester.pump(); // post-frame 置 _fail
    expect(find.text('图片解码失败,建议下载后打开'), findsOneWidget);
    expect(api.thumbCalls, isEmpty);
  });

  testWidgets('T13-8 签名悬挂(普通图片):20s 超时落失败卡,无 pending timer', (tester) async {
    final api = await _pumpMedia(
      tester,
      _asset('t13-hang'),
      stage: (a) {
        a.signHang = Completer();
      },
    );
    await tester.pump(const Duration(seconds: 19));
    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: '19s 仍在等待(未提前失败)',
    );

    await tester.pump(const Duration(seconds: 3));
    expect(
      find.text('预览图还在生成,请稍后刷新重试'),
      findsOneWidget,
      reason: 'thumbFailText 两态口径(无 thumbnail_failed=生成中)',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(api.thumbCalls, ['t13-hang']);
    // 自然结束无 pending timer:watchdog 同步取消、闸 race 计时器经超时终止的
    // abort 链(abandonAwait)取消、UI 20s timeout 随 future 完成取消。
  });

  testWidgets('T13-9 管线 clear(句柄收到 null)仍 mounted → 置失败卡不转圈', (tester) async {
    await _pumpMedia(
      tester,
      _asset('t13-null'),
      stage: (a) {
        a.signHang = Completer();
      },
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    thumbPipeline.clear(); // 句柄以 null 完成(cancel/clear 同口径)
    await tester.pump();
    expect(
      find.text('预览图还在生成,请稍后刷新重试'),
      findsOneWidget,
      reason: 'W6 #23:收到 null 仍 mounted 也置 _fail,防三空永久 loading',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('T13-10 read 期间 dispose → 不发起 fetchThumb(计数 0)', (tester) async {
    final gate = Completer<void>();
    ThumbDiskStore.I.debugSetReadGate(() => gate.future);
    final api = await _pumpMedia(tester, _asset('t13-rd'));
    await tester.pump(); // 进入 read 等待(闸挂起)
    expect(api.thumbCalls, isEmpty, reason: '前置:闸未放行,fetch 未发起');

    await tester.pumpWidget(const SizedBox.shrink()); // dispose(句柄尚未创建)
    gate.complete(); // 放行 read
    await tester.pump();
    expect(
      api.thumbCalls,
      isEmpty,
      reason: 'W6 #23:read 期间 dispose 直接返回,不发 fetchThumb',
    );
    expect(_stubUrls, isEmpty, reason: '亦无字节下载');
  });

  testWidgets('T13-11 clear 发生在写盘前:旧代 write 被代数丢弃(debugSetWriteGate)', (
    tester,
  ) async {
    final writeGate = Completer<void>();
    ThumbDiskStore.I.debugSetWriteGate(() => writeGate.future);
    await HttpOverrides.runZoned(() async {
      installFakeApi(_T13MsApi());
      addTearDown(() => session.api = null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(child: PreviewMedia(asset: _asset('t13-wg'))),
          ),
        ),
      );
      await _pumpUntil(
        tester,
        () => _memoryImage.evaluate().isNotEmpty,
        max: 40,
      );
      expect(
        ThumbDiskStore.I.debugHas('t13-wg'),
        isFalse,
        reason: '前置:写闸挂起中尚未落盘',
      );

      final genBefore = ThumbDiskStore.I.generation;
      ThumbDiskStore.I.clear(); // 同步升代
      expect(ThumbDiskStore.I.generation, genBefore + 1);
      writeGate.complete(); // 放行被挂起的 write
      await tester.pump();
      await tester.pump();
      expect(
        ThumbDiskStore.I.debugHas('t13-wg'),
        isFalse,
        reason: 'W1 #7:clear 升代后,捕获旧代数的 write 整体放弃(文件不落盘)',
      );
      expect(_memoryImage, findsOneWidget, reason: '已上屏字节不受写盘丢弃影响');
    }, createHttpClient: (_) => _PngHttpClient());
  });

  testWidgets('T13-12 退出预览 dispose:句柄取消、名额回收、无 pending timer', (tester) async {
    final api = await _pumpMedia(
      tester,
      _asset('t13-exit'),
      stage: (a) {
        a.signHang = Completer();
      },
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.thumbCalls, ['t13-exit'], reason: '前置:fetch 已发起且签名悬挂');
    expect(thumbPipeline.debugActiveCount, 1, reason: '前置:任务占 1 个名额');

    await tester.pumpWidget(const SizedBox.shrink()); // dispose → handle.cancel
    await tester.pump();
    expect(thumbPipeline.debugActiveCount, 0, reason: 'dispose→cancel 链立即回收名额');
    // 自然结束无 pending timer:悬挂签名经 dispose→cancel→abandonAwait 链取消
    // 闸 race 计时器,watchdog 同步取消,UI 20s timeout 随 future 完成取消。
  });
}
