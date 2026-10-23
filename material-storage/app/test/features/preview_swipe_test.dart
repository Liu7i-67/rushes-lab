/// P3 预览页横滑切张单测(target-behavior 锁):预览主体外层
/// GestureDetector(onHorizontalDragEnd),未放大时 InteractiveViewer
/// panEnabled:false 让单指横滑穿透;F9 顶栏改为 PreviewTopBar。
///
/// 手势力学已实测(外层 HDrag vs 内层 InteractiveViewer panEnabled:false):
/// tester.fling(速度 1200)能穿透到外层 onHorizontalDragEnd(速度≈位移方向),
/// 慢速 drag 会被 scale 识别器吃掉——本文件统一用 fling,对应用户「快滑」
/// 操作;慢速拖动/放大态平移见真机清单。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/preview/preview_chrome.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

/// 预览链路假 API:download-link 恒给一个本地假 URL(测试环境 Image.network
/// 由 flutter_test HttpOverrides 兜底 400 → errorBuilder 色块,不炸测试)。
class SwipeFakeAssetsApi extends FakeAssetsApi {
  SwipeFakeAssetsApi(super.api);

  final downloadLinkCalls = <String>[];

  @override
  Future<String> downloadLink(
    String assetId, {
    bool asAttachment = true,
  }) async {
    downloadLinkCalls.add(assetId);
    return 'http://preview.test/$assetId';
  }
}

class SwipeFakeMsApi extends FakeMsApi {
  SwipeFakeMsApi();

  late final _assets = SwipeFakeAssetsApi(this);

  @override
  SwipeFakeAssetsApi get assets => _assets;
}

Asset assetOf(String id) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: '2026-10-20T10:00:00Z',
  folderId: 'f1',
);

Future<void> pumpPreview(WidgetTester tester) async {
  installFakeApi(SwipeFakeMsApi());
  addTearDown(() => session.api = null);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        // 测试字体(Ahem)行高偏大:胶片条 TypeBlock 在 48px 格内会假性溢出,
        // 缩小文本度量只影响测试渲染,与被测的横滑/计数断言无关
        data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
        child: PreviewPage(
          args: PreviewArgs(
            items: [assetOf('a0'), assetOf('a1'), assetOf('a2')],
            index: 0,
            folderId: 'f1',
            canDownload: true,
            where: '项目/夹',
          ),
        ),
      ),
    ),
  );
  // 预览 URL 编排为微任务级,逐 pump 推进(加载圈为不定长动画,勿 pumpAndSettle)
  await tester.pump();
  await tester.pump();
}

Future<void> swipe(WidgetTester tester, {required bool forward}) async {
  await tester.fling(
    find.byType(PreviewMedia),
    forward ? const Offset(-350, 0) : const Offset(350, 0),
    1200,
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('P3:顶栏无左右切换钮,计数保留;左滑下一张/右滑上一张/边界即停', (tester) async {
    await pumpPreview(tester);

    // 顶部去切换钮(作用域限定 PreviewTopBar;页内其他 chevron 不受影响)
    expect(find.byType(PreviewTopBar), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PreviewTopBar),
        matching: find.byIcon(Icons.chevron_left),
      ),
      findsNothing,
      reason: 'P3:移除顶部左切换钮',
    );
    expect(
      find.descendant(
        of: find.byType(PreviewTopBar),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
      reason: 'P3:移除顶部右切换钮',
    );

    // 计数与文件名照常渲染
    expect(find.textContaining('1 / 3'), findsOneWidget);
    expect(find.text('a0.jpg'), findsWidgets);

    // 左滑(手指向左)→ 下一张
    await swipe(tester, forward: true);
    expect(find.textContaining('2 / 3'), findsOneWidget);
    expect(find.text('a1.jpg'), findsWidgets, reason: '计数与文件名随切张更新');

    // 左滑到末张,再滑边界即停
    await swipe(tester, forward: true);
    expect(find.textContaining('3 / 3'), findsOneWidget);
    await swipe(tester, forward: true);
    expect(find.textContaining('3 / 3'), findsOneWidget, reason: '末张再左滑边界即停');

    // 右滑回退,首张再滑边界即停
    await swipe(tester, forward: false);
    expect(find.textContaining('2 / 3'), findsOneWidget);
    await swipe(tester, forward: false);
    expect(find.textContaining('1 / 3'), findsOneWidget);
    await swipe(tester, forward: false);
    expect(find.textContaining('1 / 3'), findsOneWidget, reason: '首张再右滑边界即停');
    expect(find.text('a0.jpg'), findsWidgets);
  });
}
