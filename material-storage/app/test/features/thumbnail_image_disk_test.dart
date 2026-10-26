/// ThumbnailImage 磁盘缓存与平滑加载(app-polish-3 测试功能点 2/3,包 B3):
/// - 磁盘有缓存 → 不签 thumbnail-url(fake API 计数 0)直接渲染 Image;
/// - 磁盘未命中 → 签 1 次 + 下载 200 落盘,二次进入 0 次新签名;
/// - 占位态纯 ColoredBox(主题 surface3)、无 CircularProgressIndicator(用户抱怨
///   的第二段闪烁,findsNothing 钉死);
/// - 无 thumbnail_key 资产走 TypeBlock 色块且零请求;
/// - 下载非 200 降级 TypeBlock。
///
/// 网络策略:ThumbnailImage 用裸 HttpClient 下载(presigned 直连),widget 测试
/// 经 HttpOverrides 注桩客户端(每个测试体都包同一 zone,静态 _http 首次初始化
/// 即落桩;状态码/字节按用例切换),全程无真实 socket。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/preview_kind.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/core/thumb_disk_store.dart';
import 'package:ms_app/theme/app_theme.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show ThumbnailImage, thumbnailCache;
import 'package:ms_app/theme/tk_colors.dart';
import 'package:ms_app/widgets/asset_plate.dart';
import 'package:ms_app/widgets/type_block.dart';

import '../helpers/api_harness.dart';

// ── 桩 HTTP(presigned 下载直连那颗 HttpClient)──────────────────────────────

/// 桩响应编排(模块级,用例内改):非 200 走 drain→抛(降级);200 回 [bytes]。
int _stubStatus = 200;
List<int> _stubBytes = const [];

/// 桩请求已命中的 URL(断言下载目标用)。
final _stubUrls = <Uri>[];

/// 桩请求 abort 调用计数(storm-fix:abort 链可观测;现状 noSuchMethod
/// 静默 no-op——tear-off 非空不抛 TypeError,但取消行为不可见,补齐计数)。
int _abortCalls = 0;

class _StubHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    _stubUrls.add(url);
    return _StubRequest();
  }

  @override
  set connectionTimeout(Duration? _) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubRequest implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _StubResponse();

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _abortCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubResponse implements HttpClientResponse {
  @override
  final int statusCode = _stubStatus;
  final List<int> _data = _stubBytes;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> element)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([_data]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ── 假 API:thumbnailUrl 记录并可挂起 ────────────────────────────────────────

class _ThumbAssetsApi extends FakeAssetsApi {
  _ThumbAssetsApi(super.api);

  final thumbCalls = <String>[];

  /// 非 null 时签名挂起(占位态稳定性用;放弃等待不炸测试)。
  Completer<({String url, int expiresIn})>? signHang;

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) async {
    thumbCalls.add(assetId);
    final hang = signHang;
    if (hang != null) return hang.future;
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }
}

class _ThumbMsApi extends FakeMsApi {
  late final _assets = _ThumbAssetsApi(this);

  @override
  _ThumbAssetsApi get assets => _assets;
}

// ── 夹具 ─────────────────────────────────────────────────────────────────────

/// 1×1 透明 PNG(经典字节,测试内可真实解码出帧)。
final Uint8List kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Asset _asset(String id, {bool withThumb = true}) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 4,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  tags: withThumb ? const {'thumbnail_key': 'k'} : const {},
);

Widget _host(Asset asset, {Key? key}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 100,
        height: 100,
        child: ThumbnailImage(key: key, asset: asset),
      ),
    ),
  ),
);

void main() {
  late Directory dir;

  Future<void> Function(WidgetTester) inStubZone(
    Future<void> Function(WidgetTester) body,
  ) =>
      (tester) => HttpOverrides.runZoned(
        () => body(tester),
        createHttpClient: (_) => _StubHttpClient(),
      );

  setUp(() {
    thumbnailCache.clear();
    _stubStatus = 200;
    _stubBytes = const [];
    _stubUrls.clear();
    _abortCalls = 0;
    dir = Directory.systemTemp.createTempSync('thumb_img_test');
    ThumbDiskStore.I.debugAttachDirectory(dir);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 写盘 fire-and-forget 的微任务链在 fakeAsync 下不被 tester.pump flush
  /// (嵌套 zone 内注册,收尾才跑):pump 出帧 + 真实 await 提供事件循环拍
  /// 催化其推进,轮询探测落盘。
  Future<void> waitForWritten(WidgetTester tester, String assetId) async {
    for (var i = 0; i < 100; i++) {
      if (ThumbDiskStore.I.debugHas(assetId)) return;
      await tester.pump(const Duration(milliseconds: 50));
      // 真实 async 让出 isolate 一拍:催化 fire-and-forget 微任务链推进
      await ThumbDiskStore.I.read(assetId);
    }
    expect(
      ThumbDiskStore.I.debugHas(assetId),
      isTrue,
      reason: '写盘 fire-and-forget 应在 pump 轮询窗口内落地',
    );
  }

  testWidgets('P2-2:TypeBlock 浅/深主题均内置 AssetPlate,扩展名可见不抛', (tester) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(brightness),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                height: 120,
                child: TypeBlock(kind: PreviewKind.pdf, filename: 'a.pdf'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$brightness 渲染无异常');
      expect(
        find.byType(AssetPlate),
        findsOneWidget,
        reason: '$brightness:TypeBlock 复用打样卡',
      );
      expect(find.text('PDF'), findsOneWidget);
    }
  });

  testWidgets('功能点 2/3:磁盘已有缓存 → 不签 thumbnail-url(计数 0),'
      '直接渲染 Image(二次进入本地秒出)', (tester) async {
    inStubZone((tester) async {
      final api = installFakeApi(_ThumbMsApi()) as _ThumbMsApi;
      addTearDown(() => session.api = null);
      // 预写为真实文件 IO:fakeAsync 下裸 await 挂死,经 runAsync 落盘
      await tester.runAsync(() async {
        await ThumbDiskStore.I.write('cached-a', kPng1x1);
      });

      await tester.pumpWidget(_host(_asset('cached-a')));
      await tester.pumpAndSettle();

      expect(
        api.assets.thumbCalls,
        isEmpty,
        reason: '磁盘命中即秒出,不得发起任何 thumbnail-url 签名',
      );
      expect(
        find.byType(Image),
        findsOneWidget,
        reason: '磁盘位图直接上屏(消三段闪烁的第一段白屏)',
      );
      expect(find.byType(TypeBlock), findsNothing, reason: '非降级路径');
    })(tester);
  });

  testWidgets('功能点 2:磁盘未命中 → 签 1 次并落盘;二次进入 0 次新签名', (tester) async {
    inStubZone((tester) async {
      final api = installFakeApi(_ThumbMsApi()) as _ThumbMsApi;
      addTearDown(() => session.api = null);
      _stubStatus = 200;
      _stubBytes = kPng1x1;

      await tester.pumpWidget(_host(_asset('fresh-a'), key: const Key('v1')));
      // 管线/签名闸/下载链跨多拍事件队列调度,pumpAndSettle 一轮不可达:
      // 轮询推进假时钟直到字节上屏(与 preview_fallback_thumb 同配方)。
      for (var i = 0; i < 40; i++) {
        if (find.byType(Image).evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(api.assets.thumbCalls, ['fresh-a'], reason: '未命中磁盘签 1 次 URL');
      expect(
        _stubUrls.map((u) => u.toString()),
        contains('http://thumb.test/fresh-a'),
        reason: '用签名 URL 下载位图字节',
      );
      await waitForWritten(tester, 'fresh-a');
      // runAsync 轮询期间 fakeAsync 时钟未走:回来补一拍出帧再断言
      await tester.pump();
      expect(
        await ThumbDiskStore.I.read('fresh-a'),
        kPng1x1,
        reason:
            '下载成功即落盘(写盘 fire-and-forget,轮询等待落地;'
            '下次进入/URL 轮换不再整图重下)',
      );
      expect(find.byType(Image), findsOneWidget);

      // 二次进入:重建同 asset 的 ThumbnailImage(URL 内存缓存仍在)
      await tester.pumpWidget(_host(_asset('fresh-a'), key: const Key('v2')));
      for (var i = 0; i < 40; i++) {
        if (find.byType(Image).evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(api.assets.thumbCalls, [
        'fresh-a',
      ], reason: '第二格位走磁盘缓存,0 次新签名(功能点 2 的「第二次进入 0 次」)');
      expect(find.byType(Image), findsOneWidget);
    })(tester);
  });

  testWidgets('功能点 3:加载中占位为纯 ColoredBox(surface3),'
      '无 CircularProgressIndicator(用户抱怨的加载动画必须消失)', (tester) async {
    inStubZone((tester) async {
      final api = installFakeApi(_ThumbMsApi()) as _ThumbMsApi;
      addTearDown(() => session.api = null);
      api.assets.signHang = Completer(); // 签名挂起 → 恒占位态

      await tester.pumpWidget(_host(_asset('loading-a')));
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == TkColors.light.surface3,
        ),
        findsOneWidget,
        reason: '占位为 surface3 纯色块(B3 定稿;裸 MaterialApp 按浅色兜底)',
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: '占位态不含加载动画(用户原话「不要转圈」)',
      );
      expect(find.byType(Image), findsNothing);
    })(tester);
  });

  testWidgets('功能点 3:无 thumbnail_key 资产走 TypeBlock 色块,不发任何请求', (tester) async {
    inStubZone((tester) async {
      final api = installFakeApi(_ThumbMsApi()) as _ThumbMsApi;
      addTearDown(() => session.api = null);

      await tester.pumpWidget(_host(_asset('nothumb-a', withThumb: false)));
      await tester.pumpAndSettle();

      expect(
        find.byType(TypeBlock),
        findsOneWidget,
        reason: '无 thumbnail_key 与 web 同门槛:直接类型色块',
      );
      expect(
        find.byType(AssetPlate),
        findsOneWidget,
        reason: 'P2-2:TypeBlock 降级已复用金弧打样卡(非平面灰块)',
      );
      expect(find.text('JPG'), findsOneWidget, reason: '扩展名小字可读可见');
      expect(api.assets.thumbCalls, isEmpty, reason: '零签名请求');
    })(tester);
  });

  testWidgets('功能点 2:下载失败(非 200)降级 TypeBlock 色块,不白屏不转圈', (tester) async {
    inStubZone((tester) async {
      installFakeApi(_ThumbMsApi()); // 签名仍需 fake 会话;计数不断言
      addTearDown(() => session.api = null);
      _stubStatus = 404;
      _stubBytes = const [];

      await tester.pumpWidget(_host(_asset('broken-a')));
      await tester.pumpAndSettle();

      expect(_abortCalls, 0, reason: '非 200 走 drain→失败路径,abort 链未触发(可观测性冒烟)');
      expect(
        find.byType(TypeBlock),
        findsOneWidget,
        reason: '签名/下载失败降级类型色块(任一步异常置 _failed)',
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    })(tester);
  });
}
