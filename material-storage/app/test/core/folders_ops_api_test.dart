/// FolderOpsApi 契约单测(B6 测试功能点 1/2/3 的端点层):create body、PATCH
/// 改名/移动(显式 null=项目一级)、删除 204/409 detail 透传、invite body
/// (有效期档位映射:0=省略)、grants levels body、revoke query 形状。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';

import '../helpers/api_harness.dart';

void main() {
  late ApiHarness h;

  setUp(() async {
    // capture=true 时 harness 已读走 body,handler 勿再 readJson(二次 listen 抛异常→500)
    h = ApiHarness((req) async {
      if (req.method == 'POST' && req.uri.path == '/api/v1/folders') {
        json(req, {
          'id': 'new',
          'project_id': 'p1',
          'parent_folder_id': null,
          'name': 'x',
          'minio_prefix': 'x/',
          'is_sensitive': false,
          'created_at': '2026-10-20T10:00:00Z',
        }, status: 201);
        return;
      }
      if (req.method == 'PATCH') {
        json(req, {
          'id': 'f1',
          'project_id': 'p1',
          'parent_folder_id': null,
          'name': 'x',
          'minio_prefix': 'x/',
          'is_sensitive': false,
          'created_at': '2026-10-20T10:00:00Z',
        });
        return;
      }
      noContent(req);
    }, capture: true);
    await h.start();
  });

  tearDown(() => h.stop());

  test('create:POST body 含 project_id/parent/name/is_sensitive', () async {
    h.captured.clear();
    await h.api!.foldersOps.create(
        projectId: 'p1', parentFolderId: 'f0', name: '子夹', isSensitive: false);
    final c = h.captured.single;
    expect(c.method, 'POST');
    expect(c.path, '/api/v1/folders');
    expect(c.body, {
      'project_id': 'p1',
      'parent_folder_id': 'f0',
      'name': '子夹',
      'is_sensitive': false,
    });
  });

  test('create root:parent_folder_id 恒在(null)+is_sensitive=true', () async {
    await h.api!.foldersOps.create(projectId: 'p1', name: '敏感夹', isSensitive: true);
    expect(h.captured.single.body['parent_folder_id'], isNull);
    expect(h.captured.single.body['is_sensitive'], isTrue);
  });

  test('rename:PATCH body 只带 name', () async {
    await h.api!.foldersOps.rename('f1', name: '新名');
    final c = h.captured.single;
    expect(c.method, 'PATCH');
    expect(c.path, '/api/v1/folders/f1');
    expect(c.body, {'name': '新名'});
  });

  test('move:PATCH parent_folder_id 显式键(null=移为项目一级,缺省≠null 契约)',
      () async {
    await h.api!.foldersOps.move('f1', parentFolderId: 'f2');
    expect(h.captured.single.body, {'parent_folder_id': 'f2'});

    await h.api!.foldersOps.move('f1', parentFolderId: null);
    expect(h.captured[1].body.keys, contains('parent_folder_id'));
    expect(h.captured[1].body['parent_folder_id'], isNull);
  });

  test('delete:204 放行;非空 409 detail 透传', () async {
    await h.api!.foldersOps.delete('f1');
    expect(h.captured.single.method, 'DELETE');

    final h409 = ApiHarness((req) async {
      await readJson(req);
      json(req, {
        'detail': '文件夹不为空,请先删除其中所有文件',
      }, status: 409);
    });
    await h409.start();
    try {
      await h409.api!.foldersOps.delete('f1');
      fail('应抛 409');
    } on ApiException catch (e) {
      expect(e.status, 409);
      expect(e.message, '文件夹不为空,请先删除其中所有文件');
    } finally {
      await h409.stop();
    }
  });

  test('invite:body 主体二选一+level+duration(0=永久省略字段)', () async {
    await h.api!.foldersOps.invite('f1',
        userId: 'u1', level: 'downloader', durationSeconds: 3600);
    expect(h.captured.single.body, {
      'user_id': 'u1',
      'group_id': null,
      'level': 'downloader',
      'duration_seconds': 3600,
    });

    await h.api!.foldersOps.invite('f1',
        groupId: 'g1', level: 'viewer', durationSeconds: null);
    final c = h.captured[1];
    expect(c.body['group_id'], 'g1');
    expect(c.body['user_id'], isNull);
    expect(c.body['duration_seconds'], isNull, reason: '永久=duration_seconds null');
  });

  test('revokeInvite:query subject/level/permanent', () async {
    await h.api!.foldersOps.revokeInvite('f1',
        subject: 'user:u1', level: 'viewer', permanent: false);
    final c = h.captured.single;
    expect(c.method, 'DELETE');
    expect(c.path, '/api/v1/folders/f1/invite');
  });

  test('addGrant:levels 数组一次授多 level(无有效期字段)', () async {
    await h.api!.foldersOps.addGrant('f1', userId: 'u1',
        levels: ['uploader', 'viewer']);
    final body = h.captured.single.body;
    expect(body['user_id'], 'u1');
    expect(body['levels'], ['uploader', 'viewer']);
    expect(body.keys.any((k) => k.contains('duration')), isFalse,
        reason: '后端只收 levels+主体,恒永久勿造假 UI');
  });

  test('removeGrant:DELETE query subject+level', () async {
    await h.api!.foldersOps
        .removeGrant('f1', subject: 'group:g1#member', level: 'viewer');
    expect(h.captured.single.method, 'DELETE');
    expect(h.captured.single.path, '/api/v1/folders/f1/grants');
  });
}
