/// 预览页操作钮单测(B4 下载点亮保留;B5 功能点 4:分享/申请权限点亮;
/// F9 新增标签/详情两项):分享=单资产恒可点(后端 403 最终裁决);申请权限=
/// my_can_download==false 时入口可点并以金框提示;canDownload=null 中性
/// (申请不亮)。附 RefreshBus 机制件单测(原 B2 批落位于此,随迁保留)。
/// P1:带色 Container 包 SafeArea(top:false) 结构 + Row padding 保持,
/// 虚拟导航栏区域不露底色;F9 底色改用固定暗色 Tk.previewSurface。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/features/preview/preview_actions.dart';
import 'package:ms_app/theme/tokens.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required bool? canDownload,
    VoidCallback? onDownload,
    VoidCallback? onShare,
    VoidCallback? onTag,
    VoidCallback? onRequest,
    VoidCallback? onDetail,
    bool downloadQueued = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewActions(
            canDownload: canDownload,
            onDownload: onDownload,
            onShare: onShare,
            onTag: onTag,
            onRequest: onRequest,
            onDetail: onDetail,
            downloadQueued: downloadQueued,
          ),
        ),
      ),
    );
  }

  testWidgets('P2-1:320 宽 + 1.3 字号五项标签两行完整(申请权限不裁切)', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: PreviewActions(
                  canDownload: false,
                  onDownload: () {},
                  onShare: () {},
                  onTag: () {},
                  onRequest: () {},
                  onDetail: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '320/1.3 无溢出异常');
    for (final label in ['下载', '分享', '标签', '申请权限', '详情']) {
      expect(find.text(label), findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '「$label」在 2 行内完整渲染(不省略)',
      );
    }
    // 图标 21 / 字号 11 的设计规格保留。
    expect(tester.widget<Icon>(find.byIcon(Icons.download_outlined)).size, 21);
    expect(tester.widget<Text>(find.text('申请权限')).style?.fontSize, 11);
  });

  testWidgets('点亮态:canDownload=true + onDownload → 点按触发入队回调', (tester) async {
    var fired = 0;
    await pump(tester, canDownload: true, onDownload: () => fired++);
    await tester.tap(find.text('下载'));
    expect(fired, 1);
    expect(find.byTooltip('下载到本机(相册 / Download/浣花视界)'), findsOneWidget);
    expect(find.byTooltip('无下载权限 · 可申请'), findsNothing);
  });

  testWidgets('canDownload=false:下载钮禁用(点按不触发)+ 申请权限点亮可点(B5)', (tester) async {
    var downloadFired = 0;
    var requestFired = 0;
    await pump(
      tester,
      canDownload: false,
      onDownload: () => downloadFired++,
      onRequest: () => requestFired++,
    );
    await tester.tap(find.text('下载'), warnIfMissed: false);
    await tester.pump();
    expect(downloadFired, 0, reason: '已知无权 → 禁用');
    expect(find.byTooltip('无下载权限 · 可申请'), findsOneWidget);
    await tester.tap(find.text('申请权限'));
    await tester.pump();
    expect(requestFired, 1, reason: 'my_can_download==false → 申请入口可点');
  });

  testWidgets('canDownload=null(夹详情未到/失败,三态):下载中性放行,申请入口不亮', (tester) async {
    var downloadFired = 0;
    var requestFired = 0;
    await pump(
      tester,
      canDownload: null,
      onDownload: () => downloadFired++,
      onRequest: () => requestFired++,
    );
    await tester.tap(find.text('下载'));
    expect(downloadFired, 1);
    await tester.tap(find.text('申请权限'), warnIfMissed: false);
    await tester.pump();
    expect(requestFired, 0, reason: 'null=详情未到,申请入口不亮(详情到了再看)');
  });

  testWidgets('canDownload=true:申请权限禁用(已有下载权,无需申请)', (tester) async {
    var requestFired = 0;
    await pump(tester, canDownload: true, onRequest: () => requestFired++);
    expect(find.byTooltip('已有下载权限,无需申请'), findsOneWidget);
    await tester.tap(find.text('申请权限'), warnIfMissed: false);
    await tester.pump();
    expect(requestFired, 0);
  });

  testWidgets('分享钮点亮(B5):回调注入即可点;未注入时退占位「后续版本开放」', (tester) async {
    var shareFired = 0;
    await pump(
      tester,
      canDownload: true,
      onShare: () => shareFired++,
      onDownload: () {},
      onRequest: () {},
    );
    await tester.tap(find.text('分享'));
    expect(shareFired, 1);
    expect(find.byTooltip('分享链接(需登录访问)'), findsOneWidget);
    // 全回调缺省:下载/分享退占位
    await pump(tester, canDownload: true);
    expect(find.byTooltip('后续版本开放'), findsNWidgets(2));
  });

  testWidgets('P1(mobile-ux-polish):外层带色 Container + SafeArea(top:false),'
      'Row padding 保持(虚拟导航栏不遮挡、背景延伸到导航栏区域)', (tester) async {
    await pump(tester, canDownload: true);
    // 外层带色 Container(Tk.previewSurface):背景延伸到导航栏区域不露底色
    final hasPreviewSurfaceBg = tester
        .widgetList<Container>(find.byType(Container))
        .any((c) => c.color == Tk.previewSurface);
    expect(hasPreviewSurfaceBg, isTrue);
    // SafeArea 只让位底部(top:false,顶部不动)
    final safe = tester.widget<SafeArea>(find.byType(SafeArea));
    expect(safe.top, isFalse);
    expect(safe.bottom, isTrue);
    // 内容 Row 的 padding 保持 EdgeInsets.all(8)
    final padding = tester
        .widgetList<Padding>(find.byType(Padding))
        .firstWhere((p) => p.padding == const EdgeInsets.all(8));
    expect(
      find.descendant(of: find.byWidget(padding), matching: find.byType(Row)),
      findsOneWidget,
    );
  });

  testWidgets('F9:传入 onTag/onDetail 时渲染五项,三项兼容调用只渲染三项', (tester) async {
    await pump(
      tester,
      canDownload: true,
      onDownload: () {},
      onShare: () {},
      onTag: () {},
      onRequest: () {},
      onDetail: () {},
    );
    for (final label in ['下载', '分享', '标签', '申请权限', '详情']) {
      expect(find.text(label), findsOneWidget, reason: '五项操作齐全:$label');
    }

    await pump(tester, canDownload: true);
    expect(find.text('标签'), findsNothing, reason: 'onTag 缺省不渲染');
    expect(find.text('详情'), findsNothing, reason: 'onDetail 缺省不渲染');
    // 未注入回调的下载/分享退占位提示
    expect(find.byTooltip('后续版本开放'), findsNWidgets(2));
  });

  testWidgets('F9:无下载权时「申请权限」金框高亮;入队态用 previewGold', (tester) async {
    await pump(tester, canDownload: false, onDownload: () {}, onRequest: () {});
    // 申请权限文字/图标为 previewGold
    final requestText = tester.widget<Text>(find.text('申请权限'));
    expect(requestText.style?.color, Tk.previewGold);
    // 金色细框(仅高亮项)
    final framed = tester
        .widgetList<Container>(find.byType(Container))
        .where(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).border?.top.color ==
                  Tk.previewGold.withValues(alpha: 0.55),
        );
    expect(framed, isNotEmpty, reason: '申请权限金框高亮');

    await pump(
      tester,
      canDownload: true,
      onDownload: () {},
      downloadQueued: true,
    );
    final queuedText = tester.widget<Text>(find.text('已入队 ✓'));
    expect(queuedText.style?.color, Tk.previewGold);
  });

  group('RefreshBus(数据新鲜度机制件)', () {
    test('invalidate 只回调对应 scope 的监听者;重复回调到解除为止', () {
      final bus = RefreshBus();
      var projects = 0;
      var folders = 0;
      void onProjects() => projects++;
      void onFolders() => folders++;
      bus
        ..addListener('projects', onProjects)
        ..addListener('folders', onFolders);

      bus.invalidate('projects');
      expect(projects, 1);
      expect(folders, 0);

      bus.removeListener('projects', onProjects);
      bus.invalidate('projects'); // 已解除,不再回调
      expect(projects, 1);

      bus.invalidate('folders');
      expect(folders, 1);
    });

    test('invalidate 期间新增/移除监听不影响本轮遍历(快照安全)', () {
      final bus = RefreshBus();
      var calls = 0;
      void reentrant() {
        calls++;
        bus.removeListener('s', reentrant); // 遍历中自摘
      }

      bus.addListener('s', reentrant);
      bus.invalidate('s');
      bus.invalidate('s'); // 已摘除
      expect(calls, 1);
    });
  });
}
