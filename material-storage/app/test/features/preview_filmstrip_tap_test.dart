/// P3 胶片条点选与横滑的联动单测(横滑本体见 preview_swipe_test /
/// preview_page_swipe_test):底部胶片条点选切页后,计数/文件名同步,且
/// 横滑手势在切张(含切到视频张)后仍可用(P3 要求视频等非图片分支同支持
/// 横滑;外层 GestureDetector 与胶片条 onSelect 共存)。
/// 胶片条 thumbnailUrl 挂起(spinner 占位,避开 Ahem 字体 48px 格溢出噪音)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show ThumbnailImage;
import 'package:ms_app/features/preview/preview_chrome.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

class _FilmAssetsApi extends FakeAssetsApi {
  _FilmAssetsApi(super.api);

  @override
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async => 'http://presigned/$assetId';

  /// 永挂起:胶片条 FutureBuilder 停在 spinner 占位。
  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) =>
      Completer<({String url, int expiresIn})>().future;
}

class _FilmFakeMsApi extends FakeMsApi {
  late final _assets = _FilmAssetsApi(this);

  @override
  _FilmAssetsApi get assets => _assets;
}

Asset _img(String id) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 4,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  tags: const {'thumbnail_key': 'k'},
);

Asset _video(String id) => Asset(
  id: id,
  filename: '$id.mp4',
  sizeBytes: 4,
  contentType: 'video/mp4',
  createdAt: '2026-10-20T10:00:00Z',
  tags: const {'thumbnail_key': 'k'},
);

Future<void> _pump(WidgetTester tester, List<Asset> items) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  installFakeApi(_FilmFakeMsApi());
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: PreviewPage(
        args: PreviewArgs(
          items: items,
          index: 0,
          folderId: 'f1',
          canDownload: true,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('胶片条点选切张:计数与文件名联动(回归)', (tester) async {
    await _pump(tester, [_img('f1'), _img('f2'), _img('f3')]);
    await tester.tap(find.byType(ThumbnailImage).at(2));
    await tester.pump();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PreviewTopBar),
        matching: find.text('3 / 3'),
      ),
      findsOneWidget,
    );
    expect(find.text('f3.jpg'), findsWidgets, reason: 'MetaPanel 文件名随切张更新');
  });

  testWidgets('胶片条跳到视频张后横滑仍可切页(非图片分支外层手势路)', (tester) async {
    await _pump(tester, [_img('g1'), _video('g2')]);
    final media = find.byType(PreviewMedia);

    await tester.tap(find.byType(ThumbnailImage).at(1));
    await tester.pump();
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.drag(media, const Offset(400, 0));
    await tester.pump();
    expect(find.text('1 / 2'), findsOneWidget, reason: '视频张右滑可切回上一张');
  });
}
