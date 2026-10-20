/// 宫格页 RefreshBus 订阅单测(B3 测试功能点 7/6 部分):上传成功失效
/// `assets:<folderId>` → 宫格静默刷新(P2-2:旧列表保留后台重拉后 swap,
/// 不整页 spinner;B2 预留订阅落地);上传入口随 my_can_upload 显隐(沿用 §13)。
/// 用内存假 API(继承 AssetsApi/FoldersApi 覆写网络方法,纯微任务无真实 IO
/// ——widget 测试 FakeAsync 区里真实 socket 永不推进,runAsync 与 pumpWidget
/// 混用会死锁,故不落 HttpServer)。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/assets_api.dart';
import 'package:ms_app/core/api/folders_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/refresh_bus.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/assets/assets_page.dart';
import 'package:ms_app/models/models.dart';

/// 计数假 assets 列表:f9 首拉返回 1 条、其后每拉多 1 条(验证静默刷新
/// swap 后新资产出现);f0 恒空;每次调用记 hit。
class _CountingAssetsApi extends AssetsApi {
  _CountingAssetsApi(super.api);

  final hits = <String, int>{};

  @override
  Future<AssetPage> list(String folderId, {int limit = 30, int offset = 0}) async {
    hits[folderId] = (hits[folderId] ?? 0) + 1;
    final items = folderId == 'f9'
        ? [
            for (var i = 1; i <= hits[folderId]!; i++)
              {
                'id': 'a$i',
                'folder_id': 'f9',
                'filename': 'a$i.livp',
                'size_bytes': 123,
                'content_type': 'application/zip',
                'created_at': '2026-10-20T10:00:00Z',
              }
          ]
        : const <Object?>[];
    return AssetPage.fromJson({'items': items, 'total': items.length});
  }
}

/// 假单夹详情:f0 显式无上传权(已知 false 才隐藏),其余有。
class _FakeFoldersApi extends FoldersApi {
  _FakeFoldersApi(super.api);

  @override
  Future<Folder> get(String id) async => Folder(
        id: id,
        name: '夹$id',
        parentFolderId: null,
        myCanView: true,
        myCanDownload: true,
        myCanUpload: id != 'f0',
      );
}

class _FakeMsApi extends MsApi {
  _FakeMsApi() : super(baseUrl: 'http://b3.test.local');

  // getter 覆写(收窄返回类型),避免 overridden_fields lint
  late final _CountingAssetsApi _assets = _CountingAssetsApi(this);
  late final _FakeFoldersApi _folders = _FakeFoldersApi(this);

  @override
  _CountingAssetsApi get assets => _assets;

  @override
  _FakeFoldersApi get folders => _folders;
}

/// 列表调用可控挂起的假 API(第 1 次挂起=全屏首拉在途;第 2 次立即完成=
/// 静默刷新先落地):复现「全屏在途被静默丢弃 → loading 无人清」的卡死场景。
class _HangingAssetsApi extends AssetsApi {
  _HangingAssetsApi(super.api);

  final calls = <Completer<AssetPage>>[];

  @override
  Future<AssetPage> list(String folderId, {int limit = 30, int offset = 0}) {
    final c = Completer<AssetPage>();
    calls.add(c);
    if (calls.length >= 2) {
      c.complete(AssetPage.fromJson({
        'items': [
          {
            'id': 'a1',
            'folder_id': 'f9',
            'filename': 'a1.livp',
            'size_bytes': 123,
            'content_type': 'application/zip',
            'created_at': '2026-10-20T10:00:00Z',
          }
        ],
        'total': 1,
      }));
    }
    return c.future;
  }
}

class _HangingMsApi extends MsApi {
  _HangingMsApi() : super(baseUrl: 'http://b3.test.local');

  late final _HangingAssetsApi _assets = _HangingAssetsApi(this);
  late final _FakeFoldersApi _folders = _FakeFoldersApi(this);

  @override
  _HangingAssetsApi get assets => _assets;

  @override
  _FakeFoldersApi get folders => _folders;
}

void main() {
  setUp(() {
    session.api = _FakeMsApi();
  });

  testWidgets('失效 assets:<folderId> → 宫格静默刷新(P2-2:旧列表保留后台重拉后 swap)',
      (tester) async {
    final api = session.api! as _FakeMsApi;
    await tester.pumpWidget(
        MaterialApp(home: AssetsPage(folderId: 'f9', folderName: '夹f9')));
    await tester.pump(); // 首拉 future.wait 微任务落地 + setState 重建
    expect(find.text('a1.livp'), findsOneWidget);
    expect(api.assets.hits['f9'], 1);
    expect(find.byTooltip('上传'), findsOneWidget, reason: 'my_can_upload=true');

    RefreshBus.I.invalidate('assets:f9'); // 上传成功的失效同路
    await tester.pump();
    expect(api.assets.hits['f9'], 2, reason: '订阅生效:宫格自动重拉');
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'P2-2:失效驱动路径不整页 spinner,旧列表原地保留');
    expect(find.text('a1.livp'), findsOneWidget,
        reason: '重拉期间旧列表不被清空');
    expect(find.text('a2.livp'), findsOneWidget,
        reason: '重拉完成即 swap:新增资产直接可见');

    // 无关 scope 不触发本夹重拉
    RefreshBus.I.invalidate('projects');
    await tester.pump();
    expect(api.assets.hits['f9'], 2);
  });

  testWidgets('my_can_upload=false:AppBar 入口与空态引导一并隐藏(沿用 §13)',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: AssetsPage(folderId: 'f0', folderName: '夹f0')));
    await tester.pump();
    expect(find.byTooltip('上传'), findsNothing);
    expect(find.text('上传素材'), findsNothing, reason: '空文件夹引导钮同口径');
    expect(find.text('空文件夹'), findsOneWidget);
  });

  testWidgets('B3 遗留修复(测试功能点 7):全屏刷新在途+静默先完成 → loading 必清',
      (tester) async {
    final api = _HangingMsApi();
    session.api = api;
    await tester.pumpWidget(
        MaterialApp(home: AssetsPage(folderId: 'f9', folderName: '夹f9')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '全屏首拉在途(第 1 次调用挂起)');

    // 上传成功失效 → 静默刷新(第 2 次调用,先于全屏路完成)
    RefreshBus.I.invalidate('assets:f9');
    await tester.pump();
    expect(api.assets.calls.length, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: '静默 swap 落地即清全屏 loading(旧实现:_loading 被丢弃的全屏路'
            '独占,静默路不清 → 整页 spinner 永久卡死)');
    expect(find.text('a1.livp'), findsOneWidget, reason: '数据已 swap');
  });
}
