/// 测试子智能体探针(P2 批边界补测,2026-10-22)——只读验收,不入主线交付集:
/// - H1:探活中经密码框键盘 done 提交(P1-1 修复后与登录钮同口径,提交被
///       忽略不报错,决策#4 达成;原探针实证的「落登录失败错误区」已反转);
/// - H3:baseUrl 未就绪点法务链接 → 不外开、落固定错误区;
/// - G1:items<2 不渲染且首帧无异常;重选同张不触发滚动异常;
/// - G2:无缩略图资产维持原图 inline;放大签原图期间切张(取消竞态);
///       原图到达时正处放大态(替换/失败回退均不打断缩放,P2-1 改定);
/// - J1:弹层遮罩在场时 toast 悬浮其上且可点(action/body 竞态;P1-2 修复后
///       push 路由即销毁 toast、Back 首击生效,原「push 不销毁吞首击」已反转);
/// - J2:过滤态下拉刷新/进详情返回均保持过滤;
/// - I2:PickerSheet 长列表滚动+无结果态;审计项目「全部项目」重置语义。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/admin/audit_filter_bar.dart';
import 'package:ms_app/features/assets/thumbnail_image.dart'
    show ThumbnailImage, thumbnailCache;
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/features/folders/folder_row.dart';
import 'package:ms_app/features/folders/folder_tree.dart';
import 'package:ms_app/features/preview/filmstrip.dart';
import 'package:ms_app/features/preview/preview_media.dart';
import 'package:ms_app/features/preview/preview_page.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/widgets/password_field.dart';
import 'package:ms_app/widgets/pickers/picker_sheet.dart';
import 'package:ms_app/widgets/toast.dart';

import '../helpers/api_harness.dart';

// ── 假 API:downloadLink/thumbnailUrl 记录并可编排(挂起 Completer/403)──────

class _ProbeAssetsApi extends FakeAssetsApi {
  _ProbeAssetsApi(super.api);

  final downloadLinkCalls = <String>[];
  final thumbCalls = <String>[];

  /// 非 null 时 downloadLink 挂起直到 completer 完成(测取消竞态/缩放态替换)。
  Completer<String>? linkHang;

  @override
  Future<String> downloadLink(String assetId, {bool asAttachment = true}) async {
    downloadLinkCalls.add(assetId);
    final hang = linkHang;
    if (hang != null) return hang.future;
    return 'http://presigned/$assetId';
  }

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(String assetId) async {
    thumbCalls.add(assetId);
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }
}

class _ProbeMsApi extends FakeMsApi {
  late final _assets = _ProbeAssetsApi(this);

  @override
  _ProbeAssetsApi get assets => _assets;
}

Asset _img(String id, {bool withThumb = true}) => Asset(
      id: id,
      filename: '$id.jpg',
      sizeBytes: 4,
      contentType: 'image/jpeg',
      createdAt: '2026-10-20T10:00:00Z',
      tags: withThumb ? const {'thumbnail_key': 'k'} : const {},
    );

/// 预览主体(InteractiveViewer 内)正显的 Image URL(胶片条小格也是 Image,
/// 须限定预览主体取值)。
String _currentImageUrl(WidgetTester tester) {
  final image = tester.widget<Image>(
    find
        .descendant(
            of: find.byType(InteractiveViewer), matching: find.byType(Image))
        .first,
  );
  final provider = image.image;
  return (provider as NetworkImage).url;
}

/// 模拟双击(同 preview_polish2_test 口径)。
Future<void> _doubleTap(WidgetTester tester, Offset at) async {
  final g1 = await tester.startGesture(at);
  await g1.up();
  await tester.pump(kDoubleTapMinTime);
  final g2 = await tester.startGesture(at);
  await g2.up();
  await tester.pump();
}

double _mediaScale(WidgetTester tester) => tester
    .widget<InteractiveViewer>(find.byType(InteractiveViewer))
    .transformationController!
    .value
    .getMaxScaleOnAxis();

Future<({_ProbeMsApi api, _ProbeAssetsApi assets})> _pumpPreview(
  WidgetTester tester,
  PreviewArgs args,
) async {
  tester.view.physicalSize = const Size(1080, 1920);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = installFakeApi(_ProbeMsApi()) as _ProbeMsApi;
  addTearDown(() => session.api = null);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
      child: PreviewPage(args: args),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return (api: api, assets: api.assets);
}

void main() {
  setUp(() => thumbnailCache.clear());

  // ── H1:探活中键盘 done 提交(决策#4:不报错)──────────────────────────────
  testWidgets('H1 探针:探活中经密码框键盘 done 提交——提交被忽略,不报错(已修复反转)',
      (tester) async {
    session.phase = SessionPhase.probing;
    session.me = null;
    session.baseUrl = null;
    addTearDown(() {
      session.me = null;
      session.baseUrl = null;
    });
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'alice');
    await tester.pump();
    await tester.enterText(find.byType(PasswordField), 'secret');
    await tester.pump();

    // 键盘「完成」提交(探活中登录按钮禁用,唯一提交路径)
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();

    // 现状实证(P1-1,已修复反转):原实现 onSubmitted 只查 _busy 不查
    // session.phase,探活未就绪时提交绕过按钮闸门,session.login 在 api=null
    // 下抛空指针,落「登录失败,请检查网络后重试」错误区——违背决策#4
    // 「探活未完成不报错」。修复后与登录钮同口径(phase!=ready 时忽略提交),
    // 故此处断言错误区无文案(提交被静默忽略)。
    expect(find.text('登录失败,请检查网络后重试'), findsNothing,
        reason: 'P1-1 修复后:探活中键盘提交被忽略(与登录钮同口径),不落错误区');
    expect(find.text('服务不可达,请检查网络后重试'), findsNothing,
        reason: '登录流程未被触发(无任何报错文案)');
  });

  // ── H3:baseUrl 未就绪点链接 ────────────────────────────────────────────────
  testWidgets('H3 探针:baseUrl 未就绪点法务链接 → 不外开,落固定错误区',
      (tester) async {
    session.baseUrl = null;
    session.me = null;
    addTearDown(() => session.me = null);
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: LoginPage(
        openUrl: (url) async {
          opened.add(url);
          return true;
        },
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('《服务条款》'));
    await tester.pump();

    expect(opened, isEmpty, reason: 'H3:baseUrl 未就绪不发起任何外开');
    expect(find.text('打开失败,请稍后重试'), findsOneWidget,
        reason: 'H3:落固定错误区');
  });

  // ── G1:items<2 与重选同张 ────────────────────────────────────────────────
  testWidgets('G1 探针:单条目不渲染胶片条,首帧 jumpTo 无异常', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
        child: Scaffold(
          body: Filmstrip(
            items: [_img('solo')],
            index: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(ThumbnailImage), findsNothing,
        reason: 'G1:items<2 渲染 SizedBox.shrink');
    expect(find.byType(Scrollable), findsNothing);
  });

  testWidgets('G1 探针:重选同张不触发滚动异常,offset 稳定', (tester) async {
    tester.view.physicalSize = const Size(1080, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var picked = -1;
    var index = 0;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
        child: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            return Filmstrip(
              items: [for (var i = 1; i <= 60; i++) _img('r$i')],
              index: index,
              onSelect: (i) => setState(() {
                index = i;
                picked = i;
              }),
            );
          }),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    double pixels() => tester
        .state<ScrollableState>(find
            .descendant(
                of: find.byType(Filmstrip), matching: find.byType(Scrollable))
            .first)
        .position
        .pixels;

    // 点第 16 张(item index 15 = id r16,首屏内)→ 居中
    // (公式目标 = 12+15*56+24-540 = 336;一律按 asset id 定位,滚动后 .at 序号漂移)
    Finder thumb(String id) => find.byWidgetPredicate(
        (w) => w is ThumbnailImage && w.asset.id == id);
    await tester.tap(thumb('r16'));
    await tester.pumpAndSettle();
    final afterFirst = pixels();
    expect(picked, 15, reason: '前置:点选回调生效');
    expect(afterFirst, closeTo(336.0, 1.5),
        reason: '前置:index15 恒居中(公式目标 336,实证跟随正常)');

    // 重选同张(index 不变):offset 不动、无异常
    await tester.tap(thumb('r16'));
    await tester.pumpAndSettle();
    expect(picked, 15, reason: '重选命中同张(item15)');
    expect(pixels(), afterFirst, reason: 'G1:重选同张 offset 稳定');

    // 再点一张(item index 20 = id r21,当前视口内):断言再次居中且无滚动异常
    // (快速连滑收敛语义由既有 G1 横滑测试锁定)
    await tester.tap(thumb('r21'));
    await tester.pumpAndSettle();
    expect(index, 20, reason: '前置:点选 item20 生效');
    expect(picked, 20);
    expect(pixels(), closeTo(616.0, 1.5),
        reason: 'G1:连续点选后 offset 收敛到末次目标(item20 居中=616)');
  });

  // ── G2:无缩略图 / 切张取消竞态 / 缩放态替换 ─────────────────────────────
  testWidgets('G2 探针:无缩略图资产进预览维持原图 inline(老行为,直签原图)',
      (tester) async {
    final (:api, :assets) = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('raw1', withThumb: false)],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
    );
    expect(assets.thumbCalls, isEmpty, reason: '无缩略图不签 thumbnail-url');
    expect(assets.downloadLinkCalls, ['raw1'],
        reason: '无缩略图维持原图 inline(直签 download-link)');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_currentImageUrl(tester), 'http://presigned/raw1');
  });

  testWidgets('G2 探针:放大签原图期间切张,旧请求落地被丢弃(mounted 守卫)',
      (tester) async {
    final (:api, :assets) = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('a1'), _img('b2')],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
    );
    final hang = Completer<String>();
    assets.linkHang = hang;

    final center = tester.getCenter(find.byType(PreviewMedia));
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 300));
    expect(assets.downloadLinkCalls, ['a1'], reason: '前置:放大签原图(挂起中)');

    // 切张:整页换成资产 b2(ValueKey 重建,旧 State dispose)
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(0.5)),
        child: PreviewPage(
          args: PreviewArgs(
            items: [_img('b2')],
            index: 0,
            folderId: 'f1',
            canDownload: true,
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    // 旧请求此刻落地 → 若无 mounted 守卫将 setState after dispose 抛错
    hang.complete('http://presigned/a1-original');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(PreviewMedia), findsOneWidget);
    expect(_currentImageUrl(tester), 'http://thumb.test/b2',
        reason: 'G2:新张仍在缩略图,旧张原图 URL 未串入');
  });

  testWidgets('G2 探针:原图到达时正处放大态——替换/失败回退均不打断缩放(P2-1 改定)',
      (tester) async {
    final (:api, :assets) = await _pumpPreview(
      tester,
      PreviewArgs(
        items: [_img('z1')],
        index: 0,
        folderId: 'f1',
        canDownload: true,
      ),
    );
    final hang = Completer<String>();
    assets.linkHang = hang;

    final center = tester.getCenter(find.byType(PreviewMedia));
    await _doubleTap(tester, center);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_mediaScale(tester), greaterThan(2.0), reason: '前置:双击放大 2.5x');
    expect(assets.downloadLinkCalls, ['z1']);

    hang.complete('http://presigned/z1-original');
    await tester.pump();
    // AnimatedSwitcher 200ms 交叠:多 pump 几拍让退场 child 摘除(首帧 setState
    // 落在 pump1 之后,过渡实际从 pump2 起步)
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    // P2-1(修复后改定):测试区网络图恒 errorBuilder=原图下载/解码失败路径
    // ——缩略图可用态回退保持缩略图 + P7 式提示(修复前停留失败卡)。再 pump
    // 过回退后置帧回调与 200ms 回退 fade,断言稳定态。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final urls = tester
        .widgetList<Image>(find.descendant(
            of: find.byType(InteractiveViewer), matching: find.byType(Image)))
        .map((w) => (w.image as NetworkImage).url)
        .toList();
    expect(urls, ['http://thumb.test/z1'],
        reason: 'P2-1:原图解码失败回退缩略图渲染(回退态稳定)');
    expect(find.textContaining('原图不可用'), findsOneWidget,
        reason: 'P2-1:与 403 路径同观感,叠 P7 式小字提示');
    expect(_mediaScale(tester), greaterThan(2.0),
        reason: 'G2+P2-1:原图到达→替换→失败回退全程不打断缩放态(仍放大,未复位 1x)');
  });

  // ── J1:遮罩在场悬浮/竞态/push 路由 ──────────────────────────────────────
  testWidgets('J1 探针:弹层+遮罩在场时 toast 悬浮其上且条身可点销毁',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () {
                // 弹层不 await:先入遮罩,再挂 toast(条目后插→悬浮其上)
                showModalBottomSheet(
                  context: ctx,
                  builder: (_) => const SizedBox(
                      height: 120, child: Center(child: Text('SHEET内容'))),
                );
                toast(ctx, '悬浮提示');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('SHEET内容'), findsOneWidget, reason: '前置:弹层在场');
    expect(find.text('悬浮提示'), findsOneWidget, reason: 'J1:toast 出现');
    // 关键判别:toast 若被遮罩盖住,点它不会销毁(命中遮罩)
    await tester.tap(find.text('悬浮提示'));
    await tester.pumpAndSettle();
    expect(find.text('悬浮提示'), findsNothing,
        reason: 'J1:遮罩在场 toast 仍可点销毁(悬浮在弹层之上)');
    expect(find.text('SHEET内容'), findsOneWidget, reason: '弹层未受影响');
  });

  testWidgets('J1 探针:toast 存续期间 push 路由→toast 即时销毁,Back 首击生效(已修复反转)',
      (tester) async {
    // P1-2 修复后行为经真实挂载点验证:MaterialApp 挂 ToastRouteObserver
    // (同 app.dart navigatorObservers 装配;不挂 observer 的裸环境不生效)。
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [ToastRouteObserver()],
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () {
                toast(ctx, '路由存活提示');
                Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('第二页')),
                    body: const Center(child: Text('第二页内容')),
                  ),
                ));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('第二页'), findsOneWidget, reason: '前置:新路由在顶');
    // 现状实证(P1-2,已修复反转):原实现 toast entry 跨路由存活(仅被
    // 不透明路由盖为 offstage),且仍参与命中测试——第二页 AppBar 返回键
    // 首击被隐形 toast 条吞掉。修复后 toast 生命周期绑定路由变化:push 即
    // 立即摘除,offstage 残留也不存在。
    expect(find.text('路由存活提示', skipOffstage: false), findsNothing,
        reason: 'P1-2 修复后:push 路由即销毁 toast(含 offstage 残留)');

    // Back 首击生效(不再被隐形 toast 吞击)
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget,
        reason: 'P1-2 修复后:返回键首击生效,弹回首页');
  });

  testWidgets('J1 探针:条身先点(退场中)再点 action——onAction 仍触发且无双重移除异常',
      (tester) async {
    var fired = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => toast(ctx, '竞态条',
                  actionLabel: '查看', onAction: () => fired++),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('竞态条')); // 开始退场(150ms 反向)
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.text('查看'), warnIfMissed: false); // 退场中再点 action
    await tester.pumpAndSettle();

    expect(fired, 1, reason: 'J1:退场中 action 触发恰一次,无双重销毁异常');
    expect(find.text('竞态条'), findsNothing);
  });

  // ── J2:过滤态保持 ────────────────────────────────────────────────────────
  testWidgets('J2 探针:过滤态下拉刷新后过滤保持', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = [
      Project(id: 'p1', name: '婚礼A', code: 'wed-a'),
      Project(id: 'p2', name: '写字楼B', code: 'off-b'),
    ];
    session.me = Me(id: 'u1', name: '甲');
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    await tester.pumpWidget(const MaterialApp(home: ProjectsPageProbe()));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '婚礼');
    await tester.pump();
    await tester.pump();
    expect(find.text('写字楼B'), findsNothing, reason: '前置:过滤生效');

    // 下拉刷新(RefreshIndicator)
    await tester.fling(find.text('婚礼A'), const Offset(0, 250), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));

    expect(find.text('写字楼B'), findsNothing,
        reason: 'J2:过滤态下拉刷新后过滤保持');
    expect(find.text('婚礼A'), findsOneWidget);
  });

  testWidgets('J2 探针:过滤态进详情返回后过滤保持', (tester) async {
    final api = installFakeApi();
    api.projects.listStaged = [
      Project(id: 'p1', name: '婚礼A', code: 'wed-a'),
      Project(id: 'p2', name: '写字楼B', code: 'off-b'),
    ];
    session.me = Me(id: 'u1', name: '甲');
    addTearDown(() {
      session.api = null;
      session.me = null;
    });
    await tester.pumpWidget(MaterialApp(
      routes: {
        '/folders': (_) => Scaffold(
              appBar: AppBar(title: const Text('宫格页')),
              body: const Center(child: Text('宫格页内容')),
            ),
      },
      home: const ProjectsPageProbe(),
    ));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), '婚礼');
    await tester.pump();
    await tester.pump();
    expect(find.text('写字楼B'), findsNothing, reason: '前置:过滤生效');

    await tester.tap(find.text('婚礼A'));
    await tester.pumpAndSettle();
    expect(find.text('宫格页'), findsOneWidget, reason: '前置:进入下级页');

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('写字楼B'), findsNothing, reason: 'J2:返回后过滤保持');
    expect(find.text('婚礼A'), findsOneWidget);
  });

  // ── I2:PickerSheet 长列表/无结果;审计「全部项目」重置 ────────────────────
  testWidgets('I2 探针:PickerSheet 长列表可滚动;搜索无结果显示「无匹配」',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showPickerSheet<String>(
                context: ctx,
                title: '长列表',
                items: [for (var i = 1; i <= 60; i++) '选项 $i'],
                labelOf: (s) => s,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);

    // 长列表滚动:步进滚动直至深部条目可见(步幅小防过头)
    await tester.scrollUntilVisible(
      find.text('选项 40'),
      160,
      scrollable: find
          .descendant(
              of: find.byType(BottomSheet), matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('选项 40'), findsOneWidget, reason: 'I2:长列表可滚动');

    // 无结果态
    await tester.enterText(
        find.descendant(
            of: find.byType(BottomSheet), matching: find.byType(TextField)),
        '不存在xyz');
    await tester.pumpAndSettle();
    expect(find.text('无匹配'), findsOneWidget, reason: 'I2:搜索无结果空态');
  });

  testWidgets('I2 探针:审计项目筛选选后再选「全部项目」→ 回调 \'\'(重置语义)',
      (tester) async {
    var project = '';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: StatefulBuilder(builder: (context, setState) {
            return AuditFilterBar(
              eventType: '',
              projectId: project,
              actor: null,
              day: null,
              projects: [
                Project(id: 'p1', name: '婚礼A', code: 'wed-a'),
              ],
              onEventTypeChanged: (_) {},
              onProjectChanged: (v) => setState(() => project = v),
              onActorChanged: (_) {},
              onPickDate: () {},
              onClearDate: () {},
            );
          }),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('按项目筛选(可选)'), warnIfMissed: false);
    await tester.pumpAndSettle();
    // 弹层行按 ListTile 限定(字段浮标签与弹层行文案可能同文)
    await tester.tap(find.descendant(
        of: find.byType(ListTile), matching: find.text('婚礼A(wed-a)')));
    await tester.pumpAndSettle();
    expect(project, 'p1', reason: '前置:已选 p1');

    await tester.tap(find.text('婚礼A(wed-a)'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(ListTile), matching: find.text('全部项目')));
    await tester.pumpAndSettle();
    expect(project, '', reason: 'I2:「全部项目」=重置为 \'\'(null 语义保留)');
  });

  // ── K2 探针:直挂 FolderRow 已有三套测试,这里补「直属>0 且子树相同」边界 ──
  // app-polish-3 D1(2026-10-22):子树数字已整体删除,直属>0 只显示「N 项」
  // 徽标;直属=子树(平铺夹)时也不得叠出任何「子级」提示。
  testWidgets('K2 探针:直属=子树(无子夹)时只显示直属「N 项」,无任何「子级」提示',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FolderRow(
          node: FolderNode(Folder(
            id: 'k',
            name: '平铺夹',
            parentFolderId: null,
            projectId: 'p1',
            directFileCount: 7,
            subtreeFileCount: 7,
          )),
          depth: 0,
          expanded: true,
          onToggle: () {},
          onOpen: () {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('7 项'), findsOneWidget);
    expect(find.textContaining('子级'), findsNothing);
  });
}

/// J2 探针用类型别名(语义标注,行为同真实页面)。
typedef ProjectsPageProbe = ProjectsPage;
