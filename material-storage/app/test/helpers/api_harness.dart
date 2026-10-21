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

import 'package:ms_app/core/api/approvals_api.dart';
import 'package:ms_app/core/api/assets_api.dart';
import 'package:ms_app/core/api/assets_ops_api.dart';
import 'package:ms_app/core/api/folders_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
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
typedef CapturedRequest = ({String method, String path, Map<String, dynamic> body});

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
        notes: notes);

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
  Future<Asset> updateMeta(String assetId,
      {List<String>? userLabels, String? notes, String? labelsMode}) async {
    metaCalls
        .add((id: assetId, labels: userLabels, notes: notes, mode: labelsMode));
    return settleStaged(metaStaged, fakeAsset(assetId));
  }

  @override
  Future<AssetBatchPrefixResult> batchPrefix(List<String> assetIds,
      {required String action, required String prefix}) async {
    prefixCalls.add((ids: assetIds, action: action, prefix: prefix));
    return settleStaged(prefixStaged,
        AssetBatchPrefixResult(renamed: assetIds.length, skipped: 0));
  }

  @override
  Future<AssetBatchMoveResult> batchMove(List<String> assetIds,
      {required String targetFolderId}) async {
    moveCalls.add((ids: assetIds, targetFolderId: targetFolderId));
    return settleStaged(
        moveStaged, AssetBatchMoveResult(movedCount: assetIds.length));
  }

  @override
  Future<TrashPage> listTrash(String folderId,
      {int limit = 500, int offset = 0}) async {
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

  /// 按 assetId 精确编排(P2-6 部分失败用例);命中优先于全局 [deleteStaged]。
  final deleteStagedById = <String, Object?>{};

  @override
  Future<void> delete(String assetId) async {
    deleteCalls.add(assetId);
    final staged = deleteStagedById[assetId] ?? deleteStaged;
    if (staged is Exception) throw staged;
  }
}

class FakeShareApi extends ShareApi {
  FakeShareApi(super.api);

  final calls = <({String kind, String id, int expiresInSeconds})>[];
  Object? staged;
  ShareLink _fallback() => ShareLink(
      token: 'tok',
      landingUrl: 'https://ms.test/s/tok',
      expiresAt: '2026-10-30T10:00:00');

  @override
  Future<ShareLink> shareAsset(String assetId,
      {required int expiresInSeconds}) async {
    calls.add(
        (kind: 'asset', id: assetId, expiresInSeconds: expiresInSeconds));
    return settleStaged(staged, _fallback());
  }

  @override
  Future<ShareLink> shareFolder(String folderId,
      {required int expiresInSeconds}) async {
    calls.add((kind: 'folder', id: folderId, expiresInSeconds: expiresInSeconds));
    return settleStaged(staged, _fallback());
  }
}

class FakeApprovalsApi extends ApprovalsApi {
  FakeApprovalsApi(super.api);

  final calls =
      <({String targetType, String targetId, String action, int? durationSeconds, String reason})>[];
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

/// 装配并注入全局 session;测试收尾 `session.api = null`(addTearDown)。
FakeMsApi installFakeApi() {
  final api = FakeMsApi();
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
}
