/// P7 无下载权限预览降级单测(W6 改因:图片分支入口为磁盘优先/fetchThumb 取字节,
/// 不再先签原图——「inline 失败回退缩略图」的入口场景只剩视频分支与
/// 无缩略图图片;图片的原图签发失败场景移至「放大 >1.5x 后签发失败保持
/// 缩略图+提示」,见 preview_polish_test G2 用例):
/// - 图片有缩略图 → 进入直显缩略图,不签原图、无提示(G2 语义);
/// - 图片无缩略图 → 原图 inline,失败维持原「预览加载失败」卡(现状);
/// - (视频 inline 失败有缩略图 → 静态帧降级+提示,同口径,另见
///   preview_media_fallback_test)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/thumb_disk_store.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show thumbnailCache;
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 假 HttpClient:任何请求都回 200 + 1x1 PNG 字节(fetchThumb 字节下载桩;
/// 桩风格对齐 thumbnail_image_disk_test——noSuchMethod 返回 null)。
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

/// 预览降级假 API:download-link 可编排抛错,thumbnail-url 记录调用并返回假地址
/// (经全局 thumbnailCache,同产 signer 链路)。
class FallbackFakeAssetsApi extends FakeAssetsApi {
  FallbackFakeAssetsApi(super.api);

  final downloadLinkCalls = <String>[];
  final thumbCalls = <String>[];

  /// 非 null 且为 Exception 时 download-link 抛错(模拟后端 403/网络失败)。
  Object? downloadLinkStaged;

  @override
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async {
    downloadLinkCalls.add(assetId);
    final staged = downloadLinkStaged;
    if (staged is Exception) throw staged;
    return 'http://preview.test/$assetId';
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

class FallbackFakeMsApi extends FakeMsApi {
  FallbackFakeMsApi();

  late final _assets = FallbackFakeAssetsApi(this);

  @override
  FallbackFakeAssetsApi get assets => _assets;
}

Asset assetOf(String id, {Map<String, dynamic> tags = const {}}) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  folderId: 'f1',
  tags: tags,
);

/// 装配假 API(先编排后 pump)并挂 PreviewMedia;返回假 assets 记录器。
Future<FallbackFakeAssetsApi> pumpMedia(
  WidgetTester tester, {
  required Asset asset,
  Object? downloadLinkStaged,
}) async {
  final fake = (installFakeApi(FallbackFakeMsApi()) as FallbackFakeMsApi).assets
    ..downloadLinkStaged = downloadLinkStaged;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(child: PreviewMedia(asset: asset)),
      ),
    ),
  );
  // 编排链(download-link → 降级缩略图签名)均为微任务,逐 pump 推进
  // (加载圈为不定长动画,勿 pumpAndSettle)
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return fake;
}

/// 1×1 透明 PNG(经典字节,测试内可真实解码出帧)。
final Uint8List kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  late Directory dir;
  setUp(() {
    thumbnailCache.clear();
    dir = Directory.systemTemp.createTempSync('pft_thumb');
    ThumbDiskStore.I.debugAttachDirectory(dir);
  });
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
    ThumbDiskStore.I.debugAttachDirectory(null);
  });

  testWidgets('W6:图片有缩略图 miss → 签名+取字节直出,不签原图无提示(原 G2/P7 用例改因)', (
    tester,
  ) async {
    // W6 起预览缩略图走「磁盘 miss → fetchThumb(签名+字节下载)→ Image.memory」;
    // 磁盘命中路径含真实文件 IO(fakeAsync 下不可达),本用例经 HttpOverrides 假
    // HttpClient 提供字节(T12 配方:同文件首个 fetch 前装桩,静态客户端首建即被拦)。
    await HttpOverrides.runZoned(() async {
      final fake = await pumpMedia(
        tester,
        asset: assetOf('a403', tags: {'thumbnail_key': 'tk'}),
        downloadLinkStaged: ApiException(403, '无下载权限'),
      );
      // 签名(微任务)+下载(假客户端)+解码调度均经 pump 推进;解码出帧再断言
      for (var i = 0; i < 40; i++) {
        if (find.byType(InteractiveViewer).evaluate().isNotEmpty) break;
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        fake.downloadLinkCalls,
        isEmpty,
        reason: '缩略图优先,入口不签 download-link 原图(签了也不会触发)',
      );
      expect(
        fake.thumbCalls,
        contains('a403'),
        reason: 'W6:磁盘 miss 经 fetchThumb 签一次 thumbnail-url',
      );
      expect(find.textContaining('原图不可用'), findsNothing, reason: '缩略图正常直显,无提示');
      expect(find.text('预览加载失败'), findsNothing, reason: '有缩略图不落失败卡');
      expect(
        find.byType(InteractiveViewer),
        findsOneWidget,
        reason: '缩略图直显仍为图片分支(可放大)',
      );
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsOneWidget,
        reason: 'W6:预览主体直出来源为 Image.memory(fetchThumb 字节)',
      );
    }, createHttpClient: (_) => _PngHttpClient());
  });

  testWidgets('inline 403 + 无缩略图 → 维持「预览加载失败」卡,不发缩略图请求', (tester) async {
    final fake = await pumpMedia(
      tester,
      asset: assetOf('a404'),
      downloadLinkStaged: ApiException(403, '无下载权限'),
    );

    expect(
      fake.thumbCalls,
      isEmpty,
      reason: 'hasThumbnail=false 不打 thumbnail-url(既有门槛)',
    );
    expect(find.text('预览加载失败'), findsOneWidget, reason: '无缩略图时失败卡文案不变');
    expect(find.textContaining('原图不可用'), findsNothing);
  });

  testWidgets('有下载权限 → 原图 inline,无提示不发缩略图(回归)', (tester) async {
    final fake = await pumpMedia(tester, asset: assetOf('aok'));

    expect(fake.thumbCalls, isEmpty);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is NetworkImage &&
            (w.image as NetworkImage).url == 'http://preview.test/aok',
      ),
      findsOneWidget,
      reason: '正常路径仍走原图 inline URL',
    );
    expect(find.textContaining('原图不可用'), findsNothing);
  });
}
