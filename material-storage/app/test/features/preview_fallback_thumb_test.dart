/// P7 无下载权限预览降级单测(target-behavior 锁:实现落地前部分断言会红——
/// 实现于 preview_media.dart:`_loadInlineUrl()` 失败(403/网络)时,
/// asset.hasThumbnail 则回退缩略图 URL 并显示不打断的小字提示
/// 「原图不可用(无下载权限或加载失败),当前为缩略图预览」;
/// 无缩略图维持原「预览加载失败」卡)。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show thumbnailCache;
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 预览降级假 API:download-link 可编排抛错,thumbnail-url 记录调用并返回假地址
/// (经全局 thumbnailCache,同产 signer 链路)。
class FallbackFakeAssetsApi extends FakeAssetsApi {
  FallbackFakeAssetsApi(super.api);

  final downloadLinkCalls = <String>[];
  final thumbCalls = <String>[];

  /// 非 null 且为 Exception 时 download-link 抛错(模拟后端 403/网络失败)。
  Object? downloadLinkStaged;

  @override
  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async {
    downloadLinkCalls.add(assetId);
    final staged = downloadLinkStaged;
    if (staged is Exception) throw staged;
    return 'http://preview.test/$assetId';
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) async {
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
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox.expand(child: PreviewMedia(asset: asset)),
    ),
  ));
  // 编排链(download-link → 降级缩略图签名)均为微任务,逐 pump 推进
  // (加载圈为不定长动画,勿 pumpAndSettle)
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return fake;
}

void main() {
  setUp(() => thumbnailCache.clear());

  testWidgets('inline 403 + 有缩略图 → 走缩略图 URL 且提示出现,不再失败卡',
      (tester) async {
    final fake = await pumpMedia(
      tester,
      asset: assetOf('a403', tags: {'thumbnail_key': 'tk'}),
      downloadLinkStaged: ApiException(403, '无下载权限'),
    );

    expect(fake.downloadLinkCalls, contains('a403'),
        reason: '先按原图 inline 拉,失败后才降级');
    expect(fake.thumbCalls, contains('a403'),
        reason: 'P7:降级回退缩略图签名(thumbnail-url)');
    expect(find.textContaining('原图不可用'), findsOneWidget,
        reason: '显示不打断的小字提示');
    expect(find.textContaining('缩略图预览'), findsOneWidget);
    expect(find.text('预览加载失败'), findsNothing,
        reason: '有缩略图时不再出「预览加载失败」卡');
  });

  testWidgets('inline 403 + 无缩略图 → 维持「预览加载失败」卡,不发缩略图请求',
      (tester) async {
    final fake = await pumpMedia(
      tester,
      asset: assetOf('a404'),
      downloadLinkStaged: ApiException(403, '无下载权限'),
    );

    expect(fake.thumbCalls, isEmpty,
        reason: 'hasThumbnail=false 不打 thumbnail-url(既有门槛)');
    expect(find.text('预览加载失败'), findsOneWidget,
        reason: '无缩略图时失败卡文案不变');
    expect(find.textContaining('原图不可用'), findsNothing);
  });

  testWidgets('有下载权限 → 原图 inline,无提示不发缩略图(回归)', (tester) async {
    final fake = await pumpMedia(tester, asset: assetOf('aok'));

    expect(fake.thumbCalls, isEmpty);
    expect(
      find.byWidgetPredicate((w) =>
          w is Image &&
          w.image is NetworkImage &&
          (w.image as NetworkImage).url == 'http://preview.test/aok'),
      findsOneWidget,
      reason: '正常路径仍走原图 inline URL',
    );
    expect(find.textContaining('原图不可用'), findsNothing);
  });
}
