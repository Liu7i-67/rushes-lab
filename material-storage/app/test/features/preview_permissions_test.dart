/// PreviewPermissions 单测:逐素材 folderId/where 映射、页面级三态优先、
/// 按夹缓存与并发去重、失败落 null 不重试、解析后通知一次、dispose 后完成
/// 不通知不崩。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/features/preview/preview_permissions.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

class _PermFoldersApi extends FakeFoldersApi {
  _PermFoldersApi(super.api);

  final calls = <String>[];
  final results = <String, Object>{};

  @override
  Future<Folder> get(String folderId) async {
    calls.add(folderId);
    final staged = results[folderId];
    if (staged is Completer<Folder>) return staged.future;
    if (staged is Future<Folder>) return staged;
    if (staged is Exception) throw staged;
    if (staged is Folder) return staged;
    throw Exception('folder not found');
  }
}

class _PermApi extends FakeMsApi {
  late final _folders2 = _PermFoldersApi(this);

  @override
  _PermFoldersApi get folders => _folders2;
}

Asset _asset(String id) => Asset(
  id: id,
  filename: '$id.jpg',
  sizeBytes: 1,
  contentType: 'image/jpeg',
  createdAt: '2026-10-23T10:00:00Z',
);

PreviewPermissions _permissions({bool? canDownload}) => PreviewPermissions(
  folderIds: const {'a': 'fA', 'b': ''},
  wheres: const {'a': '项目A/夹A'},
  folderId: 'f-default',
  where: '默认/路径',
  canDownload: canDownload,
);

Folder _folder(String id, bool? canDownload) => Folder(
  id: id,
  name: '夹$id',
  parentFolderId: null,
  myCanDownload: canDownload,
);

void main() {
  late _PermApi fake;

  setUp(() {
    fake = _PermApi();
    installFakeApi(fake);
  });
  tearDown(() => session.api = null);

  test('folderIdOf/whereOf 逐素材映射优先,旧入口回退', () {
    final p = _permissions();
    expect(p.folderIdOf(_asset('a')), 'fA');
    expect(p.folderIdOf(_asset('b')), '', reason: '空串映射不回落页面级值');
    expect(p.folderIdOf(_asset('c')), 'f-default');
    expect(p.whereOf(_asset('a')), '项目A/夹A');
    expect(p.whereOf(_asset('c')), '默认/路径');
    p.dispose();
  });

  test('canDownload 页面级可信值优先且不发请求', () async {
    final p = _permissions(canDownload: false);
    expect(p.canDownloadFor(_asset('a')), isFalse);
    await p.ensure(_asset('a'));
    expect(fake.folders.calls, isEmpty);
    p.dispose();
  });

  test('ensure 成功落缓存,同夹只请求一次,通知一次', () async {
    fake.folders.results['fA'] = _folder('fA', true);
    final p = _permissions();
    var notified = 0;
    p.addListener(() => notified++);

    expect(p.canDownloadFor(_asset('a')), isNull);
    await p.ensure(_asset('a'));
    expect(fake.folders.calls, ['fA']);
    expect(p.canDownloadFor(_asset('a')), isTrue);
    expect(notified, 1);

    await p.ensure(_asset('a'));
    expect(fake.folders.calls, ['fA'], reason: '已解析夹走缓存');
    expect(notified, 1);
    p.dispose();
  });

  test('ensure 失败落 null(未知)且不重试', () async {
    fake.folders.results['fA'] = Exception('boom');
    final p = _permissions();
    await p.ensure(_asset('a'));
    expect(fake.folders.calls, ['fA']);
    expect(p.canDownloadFor(_asset('a')), isNull);

    await p.ensure(_asset('a'));
    expect(fake.folders.calls, ['fA'], reason: '失败夹也不重试');
    p.dispose();
  });

  test('并发 ensure 同夹只发一次请求', () async {
    final gate = Completer<Folder>();
    fake.folders.results['fA'] = gate;
    final p = _permissions();

    final first = p.ensure(_asset('a'));
    final second = p.ensure(_asset('a'));
    expect(fake.folders.calls, ['fA'], reason: '进行中去重');
    gate.complete(_folder('fA', false));
    await Future.wait([first, second]);
    expect(p.canDownloadFor(_asset('a')), isFalse);
    p.dispose();
  });

  test('dispose 后解析完成不通知不崩', () async {
    final gate = Completer<Folder>();
    fake.folders.results['fA'] = gate;
    final p = _permissions();
    final pending = p.ensure(_asset('a'));
    p.dispose();
    gate.complete(_folder('fA', true));
    await pending; // notifyListeners 已被 _disposed 拦住,否则断言失败
    expect(fake.folders.calls, ['fA']);
  });
}
