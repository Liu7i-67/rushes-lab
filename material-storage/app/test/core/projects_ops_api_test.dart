/// ProjectOpsApi 契约单测(B6 测试功能点 4/5/6 的端点层):create=ProjectCreateIn
/// 全字段(无 visibility;可选项空=省略)、deleted 分页解析、restore、
/// members roles body/query、grants 四元组 query。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  late ApiHarness h;

  setUp(() async {
    // capture=true 时 harness 已读走 body,handler 勿再 readJson(二次 listen→500)
    h = ApiHarness((req) async {
      if (req.method == 'POST' && req.uri.path == '/api/v1/projects') {
        json(req, {
          'id': 'np1',
          'code': 'demo-2026',
          'name': '演示项目',
          'artist_account': {
            'user_id': 'u9',
            'username': 'chenming',
            'name': '陈明',
            'temporary_password': 'OneTime-123',
          },
        }, status: 201);
        return;
      }
      if (req.method == 'POST' && req.uri.path.endsWith('/restore')) {
        json(req, {'ok': true, 'project_id': 'p1'});
        return;
      }
      if (req.uri.path == '/api/v1/projects/deleted') {
        json(req, {
          'items': [
            {
              'id': 'p1',
              'code': 'old',
              'name': '旧项目',
              'description': null,
              'visibility': 'private',
              'deleted_at': '2026-10-20T10:00:00Z',
              'deleted_by': null,
              'deleted_by_name': '管理员',
            }
          ],
          'total': 1,
          'limit': 20,
          'offset': 0,
        });
        return;
      }
      if (req.method == 'GET' &&
          req.uri.path == '/api/v1/projects/p1/members') {
        json(req, [
          {
            'subject': 'user:u1',
            'kind': 'user',
            'subject_id': 'u1',
            'name': '甲',
            'roles': ['admin', 'viewer'],
          }
        ]);
        return;
      }
      noContent(req);
    }, capture: true);
    await h.start();
  });

  tearDown(() => h.stop());

  test('create:全字段提交(无 visibility;bucket/admin 必填)', () async {
    final p = await h.api!.projectsOps.create(
      code: 'demo-2026',
      name: '演示项目',
      minioBucket: 'ms-dev',
      adminUserId: 'u1',
      description: '备注',
      initialGrants: const [
        GrantEntry(kind: 'user', id: 'u2', roles: ['viewer']),
        GrantEntry(kind: 'group', id: 'g1', roles: ['uploader', 'viewer']),
      ],
      folderTemplateId: 'ft1',
      artistAccount: (username: 'chenming', name: '陈明'),
    );
    expect(p.artistAccount!.temporaryPassword, 'OneTime-123');
    final body = h.captured.single.body;
    expect(body['code'], 'demo-2026');
    expect(body['minio_bucket'], 'ms-dev');
    expect(body['admin_user_id'], 'u1');
    expect(body['initial_grants'], [
      {'kind': 'user', 'id': 'u2', 'roles': ['viewer']},
      {'kind': 'group', 'id': 'g1', 'roles': ['uploader', 'viewer']},
    ]);
    expect(body['folder_template_id'], 'ft1');
    expect(body['artist_account'], {'username': 'chenming', 'name': '陈明'});
    expect(body.keys.contains('visibility'), isFalse,
        reason: '无「可见性」字段(web 表单亦无)');
  });

  test('create:可选项空 = 键省略(web useCreateProject 展开同构)', () async {
    await h.api!.projectsOps.create(
        code: 'ab', name: '最小', minioBucket: 'ms-dev', adminUserId: 'u1');
    final body = h.captured.last.body;
    expect(body.containsKey('initial_grants'), isFalse);
    expect(body.containsKey('folder_template_id'), isFalse);
    expect(body.containsKey('artist_account'), isFalse);
    expect(body.containsKey('description'), isFalse);
  });

  test('listDeleted:分页解析(deleted_by_name/desc)', () async {
    final page = await h.api!.projectsOps.listDeleted(q: '旧', limit: 20);
    expect(page.total, 1);
    expect(page.items.single.name, '旧项目');
    expect(page.items.single.deletedByName, '管理员');
    expect(h.captured.single.path, '/api/v1/projects/deleted');
  });

  test('restore:POST 200;members add roles 数组;remove query 形状', () async {
    await h.api!.projectsOps.restore('p1');
    expect(h.captured[0].method, 'POST');
    expect(h.captured[0].path, '/api/v1/projects/p1/restore');

    await h.api!.projectsOps.addMember('p1',
        groupId: 'g1', roles: ['admin', 'viewer']);
    expect(h.captured[1].body, {
      'user_id': null,
      'group_id': 'g1',
      'roles': ['admin', 'viewer'],
    });

    await h.api!.projectsOps
        .removeMember('p1', subject: 'user:u1', role: 'viewer');
    expect(h.captured[2].method, 'DELETE');
    expect(h.captured[2].path, '/api/v1/projects/p1/members');

    final members = await h.api!.projectsOps.listMembers('p1');
    expect(members.single.roles, ['admin', 'viewer']);
  });

  test('grants:四元组撤回 query', () async {
    await h.api!.projectsOps.revokeGrant('p1',
        objectType: 'sensitive_folder',
        objectId: 'f9',
        subject: 'user:u2',
        relation: 'explicit_invited_downloader');
    expect(h.captured.single.method, 'DELETE');
    expect(h.captured.single.path, '/api/v1/projects/p1/grants');
  });

  test('429 不自动重试:直接透传 detail(dio 无重试配置)', () async {
    final h429 = ApiHarness((req) async {
      await readJson(req);
      json(req, {'detail': '请求过于频繁'}, status: 429);
    });
    await h429.start();
    try {
      await h429.api!.projectsOps.restore('p1');
      fail('应抛 429');
    } on ApiException catch (e) {
      expect(e.status, 429);
      expect(e.message, '请求过于频繁');
    } finally {
      await h429.stop();
    }
  });
}
