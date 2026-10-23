/// 核心页面双主题真实冒烟(P1-4,WP12 §11.3 / §12.4-6):
/// 390×844 与 320×640 × light/dark × 系统字号 1.3,直接 pump 真实页面
/// (fake API 提供数据),不再用合成组件替代 Projects/Me/Assets/Search/
/// Transfers 等核心页。每组合断言:
/// - tester.takeException() == null(无 overflow/异常);
/// - Scaffold 背景 == 对应 `TkColors.<light|dark>.bg`;
/// - PageHeader 关键标题存在且文字色 == palette.ink;
/// - Theme/TkColors 扩展 brightness 正确 + 关键文案存在。
/// 登录页保留 disableAnimations 关桃花 ticker,全程定长 pump 不 pumpAndSettle。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/error_report/error_info.dart';
import 'package:ms_app/core/error_report/error_report_controller.dart';
import 'package:ms_app/core/polling_controller.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/core/transfers/transfer_queue.dart';
import 'package:ms_app/core/transfers/transfer_task.dart';
import 'package:ms_app/features/admin/admin_home.dart';
import 'package:ms_app/features/approvals/approvals_page.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/features/auth/login_page.dart';
import 'package:ms_app/features/baidu/baidu_page.dart';
import 'package:ms_app/features/error_report/error_report_page.dart';
import 'package:ms_app/features/me/me_page.dart';
import 'package:ms_app/features/notifications/notifications_page.dart';
import 'package:ms_app/features/permissions/my_permissions_page.dart';
import 'package:ms_app/features/projects/projects_page.dart';
import 'package:ms_app/features/search/search_page.dart';
import 'package:ms_app/features/transfers/transfers_page.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/theme/tk_colors.dart';

import '../helpers/api_harness.dart';
import '../helpers/fake_baidu.dart';
import 'smoke_harness.dart';

// ── 假 API:在 FakeMsApi 上补 assets.list(宫格页真实数据源)───────────────

class _SmokeAssetsApi extends FakeAssetsApi {
  _SmokeAssetsApi(super.api);

  AssetPage page = AssetPage(items: const [], total: 0);
  final listCalls = <String>[];

  @override
  Future<AssetPage> list(
    String folderId, {
    int limit = 30,
    int offset = 0,
  }) async {
    listCalls.add(folderId);
    return page;
  }
}

class _SmokeMsApi extends FakeMsApi {
  late final _SmokeAssetsApi _smokeAssets = _SmokeAssetsApi(this);

  /// 宫格页数据源(补 assets.list;搜索仍走父类 searchStaged)。
  _SmokeAssetsApi get smokeAssets => _smokeAssets;

  @override
  _SmokeAssetsApi get assets => _smokeAssets;
}

_SmokeMsApi _installApi() {
  final api = _SmokeMsApi();
  session.api = api;
  session.phase = SessionPhase.ready;
  session.baseUrl = 'http://smoke.test.local';
  session.entryLabel = '测试入口';
  return api;
}

// ── 各真实页面的 fake 装配 ─────────────────────────────────────────────────

Widget _projectsPage() {
  final api = _installApi();
  api.projects.listStaged = [
    Project(id: 'p1', name: '皮肤科素材', code: 'SKIN', myRoles: ['admin']),
    Project(id: 'p2', name: '外科影像', code: 'SUR'),
  ];
  session.me = Me(id: 'u1', name: 'Evan', isProjectCreator: true);
  return const ProjectsPage();
}

Widget _mePage() {
  final api = _installApi();
  api.approvalsOps.listResult = const [];
  session.me = Me(id: 'u1', name: 'Evan', isSystemAdmin: true);
  unreadPoller.unreadCount = 3;
  return const MePage();
}

Widget _assetsPage() {
  final api = _installApi();
  api.smokeAssets.page = AssetPage(
    items: [fakeAsset('a1'), fakeAsset('a2')],
    total: 2,
  );
  api.folders.getResult = Folder(
    id: 'f1',
    name: '成片夹',
    parentFolderId: null,
    projectId: 'p1',
    myCanView: true,
    myCanDownload: true,
    myCanUpload: true,
  );
  session.me = Me(id: 'u1', name: 'Evan');
  return AssetsPage(
    folderId: 'f1',
    folderName: '成片夹',
    where: '项目一/成片夹',
    transferQueue: TransferQueue(),
  );
}

Widget _searchIdlePage() {
  _installApi();
  session.me = Me(id: 'u1', name: 'Evan');
  return const SearchPage();
}

Widget _searchPage() {
  // 结果用 2 字符扩展名 .md:44px 回退块在 flutter_test 默认 Ahem 字体
  // (每字宽=字号)下,3 字符扩展名会因 0.1px 超宽整串换行触发**测试字体
  // 专属**纵向溢出;真实字体不换行。冒烟聚焦页面级主题/尺寸,故取两字符。
  final api = _installApi();
  api.assets.searchStaged.add([
    SearchResult(
      asset: Asset(
        id: 'a1',
        filename: '报表预览.md',
        sizeBytes: 2048,
        contentType: 'text/markdown',
        createdAt: '2026-10-20T10:00:00Z',
        folderId: 'f1',
      ),
      folderName: '成片夹',
      projectId: 'p1',
      projectName: '项目一',
    ),
  ]);
  session.me = Me(id: 'u1', name: 'Evan');
  return const SearchPage();
}

Future<void> _searchAndSettle(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '报表');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Widget _transfersPage() {
  final q = TransferQueue();
  // 进行中:totalBytes=0(契约「未知」,进度条 indeterminate,卡片走 active 行;
  // Ahem 测试字体下长进度串宽度失真,未知总量是等价的真实 active 形态);
  // 完成:终态行。两条覆盖传输卡两分支。
  q.enqueue(
    TransferRequest(
      kind: TransferKind.upload,
      filename: 'r1.mov',
      where: '项目一/成片夹',
      totalBytes: 0,
      worker: (progress, token) async {
        await Completer<void>().future; // 进行中:保持 running
      },
    ),
  );
  q.enqueue(
    TransferRequest(
      kind: TransferKind.download,
      filename: 'd1.jpg',
      where: '项目一/成片夹',
      totalBytes: 200,
      worker: (progress, token) async {},
    ),
  );
  return TransfersPage(queue: q);
}

Widget _transfersEmptyPage() => TransfersPage(queue: TransferQueue());

Widget _notificationsPage() {
  final api = _installApi();
  api.notifications.listStaged = NotificationsList(
    items: [notificationOf('n1')],
    total: 1,
    unreadCount: 1,
  );
  return NotificationsPage(poller: UnreadPoller());
}

Approval _approval({String status = 'pending'}) => Approval(
  id: 'ap1',
  applicantUserId: 'u9',
  targetType: 'asset',
  targetId: 'a1',
  action: 'download',
  durationSeconds: 86400,
  reason: '关单需要源文件',
  status: status,
  decidedAt: status == 'approved' ? '2026-10-20T09:30:00Z' : null,
  createdAt: '2026-10-20T09:00:00Z',
  requesterName: '小王',
  targetName: 'A001.jpg',
  parentProjectId: 'p1',
);

Widget _approvalsPage() {
  final api = _installApi();
  session.me = Me(id: 'u0', name: '管理员', isSystemAdmin: true);
  api.approvalsOps.listResult = [_approval()];
  return const ApprovalsPage();
}

Widget _myPermissionsPage() {
  final api = _installApi();
  session.me = Me(id: 'u1', name: 'Evan');
  api.projects.listStaged = [
    Project(id: 'p1', name: '皮肤科素材', code: 'SKIN', myRoles: ['admin']),
  ];
  api.approvalsOps.listResult = [_approval(status: 'approved')];
  return const MyPermissionsPage();
}

Widget _baiduPage() {
  _installApi();
  final adapter = FakeBaiduAdapter((req) async {
    if (req.path.endsWith('/binding')) {
      return {
        'bound': true,
        'status': 'active',
        'expires_at': '2026-11-20T00:00:00Z',
        'baidu_uid': 'uid-9',
        'nickname': '测试盘',
      };
    }
    if (req.path.endsWith('/tasks')) {
      return {
        'items': [
          taskJson('t1', totalFiles: 10, doneFiles: 4, etaSeconds: 120),
        ],
        'total': 1,
      };
    }
    return {'items': [], 'total': 0};
  });
  return BaiduPage(api: baiduApiWith(adapter));
}

Widget _adminHomePage() {
  _installApi();
  session.me = Me(id: 'u0', name: '管理员', isSystemAdmin: true);
  return const AdminHomePage();
}

Widget _errorReportPage() {
  _installApi();
  errorReporter.currentError = ErrorInfo(
    kind: ErrorKind.api,
    time: DateTime(2026, 10, 23, 12, 34, 56),
    source: 'GET /api/v1/projects',
    status: 500,
    message: '项目列表加载失败',
  );
  return const ErrorReportPage();
}

/// 报错页卸载会启动 3s 冷却 Timer;推进过期并复位 controller。
Future<void> _disposeErrorReportPage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
  errorReporter.reset();
}

// ── 用例表 ─────────────────────────────────────────────────────────────────

class _SmokeCase {
  const _SmokeCase({
    required this.name,
    required this.title,
    required this.keyword,
    required this.build,
    this.afterPump,
    this.cleanup,
  });

  final String name;
  final String title;
  final String keyword;
  final Widget Function() build;
  final Future<void> Function(WidgetTester)? afterPump;
  final Future<void> Function(WidgetTester)? cleanup;
}

final List<_SmokeCase> _cases = [
  _SmokeCase(name: '项目页', title: '项目', keyword: '皮肤科素材', build: _projectsPage),
  _SmokeCase(name: '我的页', title: '我的', keyword: '协作', build: _mePage),
  _SmokeCase(
    name: '素材宫格页',
    title: '成片夹',
    keyword: 'a1.jpg',
    build: _assetsPage,
  ),
  _SmokeCase(
    name: '搜索页(未搜索态)',
    title: '搜索',
    keyword: '输入关键词搜索项目内资产',
    build: _searchIdlePage,
  ),
  _SmokeCase(
    name: '搜索页',
    title: '搜索',
    keyword: '报表预览.md',
    build: _searchPage,
    afterPump: _searchAndSettle,
  ),
  _SmokeCase(
    name: '传输页(空态)',
    title: '传输',
    keyword: '暂无传输任务',
    build: _transfersEmptyPage,
  ),
  _SmokeCase(
    name: '传输页',
    title: '传输',
    keyword: 'r1.mov',
    build: _transfersPage,
  ),
  _SmokeCase(
    name: '通知页',
    title: '通知',
    keyword: '标题n1',
    build: _notificationsPage,
  ),
  _SmokeCase(name: '审批中心', title: '审批中心', keyword: '小王', build: _approvalsPage),
  _SmokeCase(
    name: '我的权限页',
    title: '我的权限',
    keyword: '项目角色',
    build: _myPermissionsPage,
  ),
  _SmokeCase(name: '网盘备份页', title: '网盘备份', keyword: '备份任务', build: _baiduPage),
  _SmokeCase(
    name: '管理后台',
    title: '管理后台',
    keyword: '用户组',
    build: _adminHomePage,
  ),
  _SmokeCase(
    name: '报错页',
    title: '应用错误',
    keyword: '已捕获错误',
    build: _errorReportPage,
    cleanup: _disposeErrorReportPage,
  ),
];

void _resetSession() {
  session.api = null;
  session.me = null;
  session.phase = SessionPhase.probing;
  session.baseUrl = null;
  session.entryLabel = '';
  unreadPoller.unreadCount = 0;
  errorReporter.reset();
}

void main() {
  setUp(_resetSession);
  tearDown(_resetSession);

  for (final size in kSmokeSizes) {
    for (final b in kSmokeBrightnesses) {
      final combo = smokeComboLabel(size, b);

      testWidgets('登录页 $combo:无异常且背景随主题', (tester) async {
        await pumpSmokePage(
          tester,
          size: size,
          brightness: b,
          home: Builder(
            builder: (ctx) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
              child: const LoginPage(),
            ),
          ),
        );

        expect(find.text('登录'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '登录页 $combo 无 overflow');
        final scaffolds = find.byType(Scaffold);
        final scaffold = tester.widget<Scaffold>(scaffolds.first);
        final theme = Theme.of(tester.element(scaffolds.first));
        expect(theme.brightness, b);
        expect(
          scaffold.backgroundColor ?? theme.scaffoldBackgroundColor,
          TkColors.of(b).bg,
          reason: '登录页背景 = $combo palette.bg',
        );
        expectSmokeTextScale(tester);
      });

      for (final c in _cases) {
        testWidgets('${c.name} $combo:真实页面无异常且主题/字号正确', (tester) async {
          final home = c.build();
          await pumpSmokePage(tester, size: size, brightness: b, home: home);
          await c.afterPump?.call(tester);
          expectSmokeBaseline(
            tester,
            brightness: b,
            title: c.title,
            keyword: c.keyword,
          );
          await c.cleanup?.call(tester);
        });
      }
    }
  }
}
