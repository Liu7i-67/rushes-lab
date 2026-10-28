/// B5 批测试通用两件:
/// 1. [ApiHarness]+json/noContent:本地 HttpServer(仅 plain test() 用;widget
///    测试 FakeAsync 区真实 socket 永不推进、HTTP 恒 400,见
///    assets_page_refresh_test 头注,禁用于 testWidgets);
/// 2. [FakeMsApi] 记录式假 API 族:testWidgets 用,覆写 B5 网络方法记录入参、
///    结果可编排(异常注入测 403/422 透传)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:ms_app/core/api/approvals_api.dart';
import 'package:ms_app/core/api/approvals_ops_api.dart';
import 'package:ms_app/core/api/assets_api.dart';
import 'package:ms_app/core/api/assets_ops_api.dart';
import 'package:ms_app/core/api/folders_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/api/notifications_api.dart';
import 'package:ms_app/core/api/projects_api.dart';
import 'package:ms_app/core/api/share_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';

import 'fake_apis_b6.dart';

// ── 1. plain-test 本地服务器 ──────────────────────────────────────────────────

Future<Map<String, dynamic>> readJson(HttpRequest req) async {
  final body = await utf8.decoder.bind(req).join();
  return body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(body) as Map<String, dynamic>;
}

void json(HttpRequest req, Object? data, {int status = 200}) {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(data));
  // 必须 close 否则 keep-alive 连接永不结束,客户端读 body 挂死
  req.response.close().ignore();
}

void noContent(HttpRequest req) {
  req.response.statusCode = 204;
  req.response.close().ignore();
}

/// 已捕获请求:(method:, path:, body:) 具名字段,解构 `(:method, :path, :body)`。
typedef CapturedRequest = ({
  String method,
  String path,
  Map<String, dynamic> body,
});

class ApiHarness {
  ApiHarness(this._handler, {this.capture = false});

  final Future<void> Function(HttpRequest req) _handler;

  /// true = 每个请求先记 (method,path,body) 再走 [_handler]。
  final bool capture;
  final captured = <CapturedRequest>[];

  HttpServer? _server;
  MsApi? api;

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      try {
        if (capture) {
          final body = await readJson(req);
          captured.add((method: req.method, path: req.uri.path, body: body));
        }
        await _handler(req);
      } catch (_) {
        req.response.statusCode = 500;
        await req.response.close();
      }
    });
    api = MsApi(baseUrl: 'http://127.0.0.1:${server.port}');
    session.api = api;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    session.api = null;
    session.me = null;
  }
}

// ── 2. testWidgets 记录式假 API 族 ───────────────────────────────────────────

Asset fakeAsset(String id, {List<String> labels = const [], String? notes}) =>
    Asset(
      id: id,
      filename: '$id.jpg',
      sizeBytes: 1,
      contentType: 'image/jpeg',
      createdAt: '2026-10-20T10:00:00Z',
      folderId: 'f1',
      userLabels: labels,
      notes: notes,
    );

/// 结果编排(公开,B6 假 API 族共用):值为 Exception 则抛,否则原样返回(缺省回退)。
T settleStaged<T>(Object? staged, T fallback) {
  if (staged is Exception) throw staged;
  return (staged ?? fallback) as T;
}

/// B5 操作族假 API(打标/前缀/移动/回收站;对应 MsApi.ops)。
class FakeOpsApi extends AssetOpsApi {
  FakeOpsApi(super.api);

  final metaCalls =
      <({String id, List<String>? labels, String? notes, String? mode})>[];
  final prefixCalls = <({List<String> ids, String action, String prefix})>[];
  final moveCalls = <({List<String> ids, String targetFolderId})>[];
  final trashCalls = <({String folderId, int limit, int offset})>[];
  final restoreCalls = <String>[];

  Object? metaStaged;
  Object? prefixStaged;
  Object? moveStaged;
  Object? trashStaged = TrashPage(items: [], total: 0);
  Object? restoreStaged;

  @override
  Future<Asset> updateMeta(
    String assetId, {
    List<String>? userLabels,
    String? notes,
    String? labelsMode,
  }) async {
    metaCalls.add((
      id: assetId,
      labels: userLabels,
      notes: notes,
      mode: labelsMode,
    ));
    return settleStaged(metaStaged, fakeAsset(assetId));
  }

  @override
  Future<AssetBatchPrefixResult> batchPrefix(
    List<String> assetIds, {
    required String action,
    required String prefix,
  }) async {
    prefixCalls.add((ids: assetIds, action: action, prefix: prefix));
    return settleStaged(
      prefixStaged,
      AssetBatchPrefixResult(renamed: assetIds.length, skipped: 0),
    );
  }

  @override
  Future<AssetBatchMoveResult> batchMove(
    List<String> assetIds, {
    required String targetFolderId,
  }) async {
    moveCalls.add((ids: assetIds, targetFolderId: targetFolderId));
    return settleStaged(
      moveStaged,
      AssetBatchMoveResult(movedCount: assetIds.length),
    );
  }

  @override
  Future<TrashPage> listTrash(
    String folderId, {
    int limit = 500,
    int offset = 0,
  }) async {
    trashCalls.add((folderId: folderId, limit: limit, offset: offset));
    return settleStaged(trashStaged, TrashPage(items: [], total: 0));
  }

  @override
  Future<void> restore(String assetId) async {
    restoreCalls.add(assetId);
    if (restoreStaged is Exception) throw restoreStaged!;
  }
}

/// 删除/下载等存量资产端点假 API(对应 MsApi.assets)。
class FakeAssetsApi extends AssetsApi {
  FakeAssetsApi(super.api);

  final deleteCalls = <String>[];
  Object? deleteStaged;

  // B7:盲搜记录+桩(逐次排队;空则回 [])。
  final searchCalls = <({String q, int limit})>[];
  final searchStaged = <Object?>[];

  @override
  Future<List<SearchResult>> search(
    String q, {
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    searchCalls.add((q: q, limit: limit));
    final staged = searchStaged.isNotEmpty ? searchStaged.removeAt(0) : null;
    return settleStaged(staged, const <SearchResult>[]);
  }

  /// 按 assetId 精确编排(P2-6 部分失败用例);命中优先于全局 [deleteStaged]。
  final deleteStagedById = <String, Object?>{};

  @override
  Future<void> delete(String assetId) async {
    deleteCalls.add(assetId);
    final staged = deleteStagedById[assetId] ?? deleteStaged;
    if (staged is Exception) throw staged;
  }

  // storm-fix(T11①/T12/T13):缩略图三端点桩。记录调用、可编排:
  // staged 为 Exception(如 ApiException(404))则抛,否则按缺省/定制返回。
  // (字段命名避开既有用例子类的 thumbCalls/thumbStaged,防字段遮蔽。)
  /// 单发签名(thumbnailUrl):staged 异常时抛(404 隔离宫格单发兜底),
  /// null=缺省即回假地址。命中计数见 [thumbUrlCalls]。
  final thumbUrlCalls = <String>[];
  Object? thumbUrlStaged;

  @override
  Future<({String url, int expiresIn})> thumbnailUrl(
    String assetId, {
    required String size,
  }) async {
    thumbUrlCalls.add(assetId);
    final staged = thumbUrlStaged;
    if (staged is Exception) throw staged;
    return (url: 'http://thumb.test/$assetId', expiresIn: 1800);
  }

  /// 批量签名(宫格预热):记录分批入参(≤100/批);staged 为 Exception 则
  /// 抛(失败静默用例),`Map<String,String>`(id→url) 定制返回,缺省全量回
  /// 假地址、missing 空。
  final thumbnailUrlsCalls = <List<String>>[];
  Object? thumbnailUrlsStaged;

  @override
  Future<
    ({Map<String, ({String url, int expiresIn})> byId, Set<String> missing})
  >
  thumbnailUrls(List<String> assetIds, {String? size}) async {
    thumbnailUrlsCalls.add(List.of(assetIds));
    final staged = thumbnailUrlsStaged;
    if (staged is Exception) throw staged;
    final custom = staged is Map<String, String> ? staged : null;
    return (
      byId: {
        for (final id in assetIds)
          id: (url: custom?[id] ?? 'http://thumb.test/$id', expiresIn: 1800),
      },
      missing: const <String>{},
    );
  }

  /// livp 实况短片:记录调用;staged 为 Exception 则抛(403/404 静默回退
  /// 静态图),null=缺省回假地址。
  final livePreviewCalls = <String>[];
  Object? livePreviewStaged;

  @override
  Future<({String url, int expiresIn})> livePreviewUrl(String assetId) async {
    livePreviewCalls.add(assetId);
    final staged = livePreviewStaged;
    if (staged is Exception) throw staged;
    return (url: 'http://live.test/$assetId', expiresIn: 1800);
  }
}

class FakeShareApi extends ShareApi {
  FakeShareApi(super.api);

  final calls = <({String kind, String id, int expiresInSeconds})>[];
  Object? staged;
  ShareLink _fallback() => ShareLink(
    token: 'tok',
    landingUrl: 'https://ms.test/s/tok',
    expiresAt: '2026-10-30T10:00:00',
  );

  @override
  Future<ShareLink> shareAsset(
    String assetId, {
    required int expiresInSeconds,
  }) async {
    calls.add((kind: 'asset', id: assetId, expiresInSeconds: expiresInSeconds));
    return settleStaged(staged, _fallback());
  }

  @override
  Future<ShareLink> shareFolder(
    String folderId, {
    required int expiresInSeconds,
  }) async {
    calls.add((
      kind: 'folder',
      id: folderId,
      expiresInSeconds: expiresInSeconds,
    ));
    return settleStaged(staged, _fallback());
  }
}

class FakeApprovalsApi extends ApprovalsApi {
  FakeApprovalsApi(super.api);

  final calls =
      <
        ({
          String targetType,
          String targetId,
          String action,
          int? durationSeconds,
          String reason,
        })
      >[];
  Object? staged;

  @override
  Future<void> create({
    required String targetType,
    required String targetId,
    required String action,
    int? durationSeconds,
    required String reason,
  }) async {
    calls.add((
      targetType: targetType,
      targetId: targetId,
      action: action,
      durationSeconds: durationSeconds,
      reason: reason,
    ));
    if (staged is Exception) throw staged!;
  }
}

class FakeFoldersApi extends FoldersApi {
  FakeFoldersApi(super.api);

  List<Folder> listResult = const [];
  Object? listStaged;
  Folder? getResult;

  @override
  Future<List<Folder>> list(String projectId) async {
    if (listStaged is Exception) throw listStaged!;
    return listResult;
  }

  @override
  Future<Folder> get(String folderId) async {
    final r = getResult;
    if (r == null) throw ApiException(404, 'folder not found');
    return r;
  }
}

/// B7:审批列表+决策假 API(对应 MsApi.approvalsOps)。list 记录
/// (scope,status) 口径;决策记录 (id, approve, note) 且可挂异常测 403 透传。
class FakeApprovalOpsApi extends ApprovalOpsApi {
  FakeApprovalOpsApi(super.api);

  final listCalls = <({String scope, String? status})>[];
  final decideCalls = <({String id, bool approve, String? note})>[];
  List<Approval> listResult = const [];
  Object? decideStaged;

  /// list 逐次排队编排(空则回 [listResult]):元素为 `List<Approval>` /
  /// Exception / `Completer<List<Approval>>`(挂起该次响应,P2-3 代际用例
  /// 「切段后放行旧段」编排)。与 searchStaged 同款队列语义。
  List<Object?> listStaged = <Object?>[];

  @override
  Future<List<Approval>> list({
    String scope = 'self',
    String? status,
    int limit = 50,
    int offset = 0,
  }) async {
    listCalls.add((scope: scope, status: status));
    final staged = listStaged.isNotEmpty ? listStaged.removeAt(0) : null;
    if (staged is Completer<List<Approval>>) return staged.future;
    return settleStaged(staged, listResult);
  }

  @override
  Future<Approval> approve(String id, {String? decisionNote}) =>
      _decide(id, approve: true, decisionNote: decisionNote);

  @override
  Future<Approval> reject(String id, {String? decisionNote}) =>
      _decide(id, approve: false, decisionNote: decisionNote);

  Future<Approval> _decide(
    String id, {
    required bool approve,
    String? decisionNote,
  }) async {
    decideCalls.add((id: id, approve: approve, note: decisionNote));
    if (decideStaged is Exception) throw decideStaged!;
    return _approvalOf(id, approve);
  }
}

Approval _approvalOf(String id, bool approved) => Approval(
  id: id,
  applicantUserId: 'u9',
  targetType: 'asset',
  targetId: 'a1',
  action: 'download',
  durationSeconds: 3600,
  reason: '关单需要',
  status: approved ? 'approved' : 'rejected',
  createdAt: '2026-10-20T09:00:00Z',
  requesterName: '申请人',
);

/// B7:通知假 API(对应 MsApi.notifications)。
class FakeNotificationsApi extends NotificationsApi {
  FakeNotificationsApi(super.api);

  final listCalls = <({int limit, int offset})>[];
  final markReadCalls = <({List<String>? ids, bool all})>[];
  NotificationsList listStaged = NotificationsList(
    items: const [],
    total: 0,
    unreadCount: 0,
  );
  Object? markReadStaged;

  /// B9 分页编排钩子:非 null 时按 (limit, offset) 返回,优先于 [listStaged]。
  NotificationsList Function({required int limit, required int offset})?
  onListOverride;

  @override
  Future<NotificationsList> list({
    int limit = 50,
    int offset = 0,
    bool silent = false,
  }) async {
    listCalls.add((limit: limit, offset: offset));
    final ovr = onListOverride;
    if (ovr != null) return ovr(limit: limit, offset: offset);
    return listStaged;
  }

  @override
  Future<int> markRead({List<String>? ids, bool all = false}) async {
    markReadCalls.add((ids: ids, all: all));
    if (markReadStaged is Exception) throw markReadStaged!;
    // 模拟已读语义:listStaged 原地置已读 + unread_count 同步(badge 对账断言用)
    final readAt = '2026-10-20T10:00:00Z';
    final items = listStaged.items
        .map(
          (n) => (all || (ids ?? const []).contains(n.id))
              ? NotificationItem(
                  id: n.id,
                  kind: n.kind,
                  title: n.title,
                  body: n.body,
                  link: n.link,
                  readAt: n.readAt ?? readAt,
                  createdAt: n.createdAt,
                )
              : n,
        )
        .toList();
    final unread = items.where((n) => n.readAt == null).length;
    listStaged = NotificationsList(
      items: items,
      total: listStaged.total,
      unreadCount: unread,
    );
    return ids?.length ??
        listStaged.items.where((n) => n.readAt != null).length;
  }
}

NotificationItem notificationOf(
  String id, {
  String kind = 'approval_pending',
  bool unread = true,
  String? link,
}) => NotificationItem(
  id: id,
  kind: kind,
  title: '标题$id',
  body: '正文$id',
  link: link,
  readAt: unread ? null : '2026-10-20T09:00:00Z',
  createdAt: '2026-10-20T09:00:00Z',
);

/// B7:项目列表假 API(对应 MsApi.projects;通知 folder_invite 跳转反查
/// 项目名/my_roles 用)。
class FakeProjectsApi extends ProjectsApi {
  FakeProjectsApi(super.api);

  int listCalls = 0;
  Object? listStaged;

  /// B5 置顶:pin/unpin 调用记录(基类新方法走真实 dio,widget 测试
  /// FakeAsync 区永不落网,必须覆写假实现)。
  final pinCalls = <String>[];
  final unpinCalls = <String>[];

  @override
  Future<List<Project>> list() async {
    listCalls++;
    if (listStaged is Exception) throw listStaged!;
    return (listStaged as List<Project>?) ?? const [];
  }

  @override
  Future<void> pin(String projectId) async {
    pinCalls.add(projectId);
  }

  @override
  Future<void> unpin(String projectId) async {
    unpinCalls.add(projectId);
  }
}

/// 装配并注入全局 session;测试收尾 `session.api = null`(addTearDown)。
/// [override] 供域覆写变体(B9 向导:FakeMsApi 子类覆写 baidu 域)注入。
FakeMsApi installFakeApi([FakeMsApi? override]) {
  final api = override ?? FakeMsApi();
  session.api = api;
  return api;
}

class FakeMsApi extends MsApi {
  FakeMsApi() : super(baseUrl: 'http://b5.test.local');

  late final _assets = FakeAssetsApi(this);
  late final _ops = FakeOpsApi(this);
  late final _share = FakeShareApi(this);
  late final _approvals = FakeApprovalsApi(this);
  late final _folders = FakeFoldersApi(this);
  late final _foldersOps = FakeFolderOpsApi(this);
  late final _projectsOps = FakeProjectOpsApi(this);
  late final _adminTemplates = FakeAdminTemplatesApi(this);
  late final _users = FakeUsersApi(this);
  late final _approvalsOps = FakeApprovalOpsApi(this);
  late final _notifications = FakeNotificationsApi(this);
  late final _projects = FakeProjectsApi(this);

  @override
  FakeAssetsApi get assets => _assets;

  @override
  FakeOpsApi get ops => _ops;

  @override
  FakeShareApi get share => _share;

  @override
  FakeApprovalsApi get approvals => _approvals;

  @override
  FakeFoldersApi get folders => _folders;

  @override
  FakeFolderOpsApi get foldersOps => _foldersOps;

  @override
  FakeProjectOpsApi get projectsOps => _projectsOps;

  @override
  FakeAdminTemplatesApi get adminTemplates => _adminTemplates;

  @override
  FakeUsersApi get users => _users;

  @override
  FakeApprovalOpsApi get approvalsOps => _approvalsOps;

  @override
  FakeNotificationsApi get notifications => _notifications;

  @override
  FakeProjectsApi get projects => _projects;
}
