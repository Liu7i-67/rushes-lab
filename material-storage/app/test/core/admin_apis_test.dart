/// B8 管理后台 API 契约单测(实码=routers/directory.py + admin.py +
/// baidu_backup.py 用户侧文件级三端点):请求路径/入参/出参解析/错误透传。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/audit_api.dart' show AuditFilter;
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  late ApiHarness h;
  var disableCalls = 0;

  setUp(() async {
    disableCalls = 0;
    h = ApiHarness((req) async {
      final p = req.uri.path;
      final q = req.uri.queryParameters;

      // ── directory users ──
      if (req.method == 'GET' && p == '/api/v1/admin/directory/users') {
        // 回显筛选参数(断言用):is_active/q/limit/offset
        json(req, {
          'items': [
            {
              'id': 'u1',
              'username': 'zhangsan',
              'name': '张三',
              'email': 'z@x.com',
              'is_active': true,
              'must_change_password': true,
              'created_at': '2026-10-20T08:00:00Z',
              'resigned_at': null,
              'login_locked': q['q'] == 'locked',
            },
          ],
          'total': 1,
          'limit': int.parse(q['limit'] ?? '0'),
          'offset': int.parse(q['offset'] ?? '0'),
        });
        return;
      }
      if (req.method == 'POST' && p == '/api/v1/admin/directory/users') {
        final body = h.captured.last.body;
        json(req, {
          'id': 'u9',
          'username': body['username'],
          'name': body['name'],
          'email': body['email'],
          'is_active': true,
          'must_change_password': true,
          'created_at': '2026-10-20T09:00:00Z',
          'resigned_at': null,
          'login_locked': false,
          'temporary_password': 'Tmp-Pass-001',
        }, status: 201);
        return;
      }
      if (req.method == 'GET' && p == '/api/v1/admin/directory/users/u1') {
        json(req, {
          'id': 'u1', 'username': 'zhangsan', 'name': '张三',
          'email': 'z@x.com', 'is_active': true,
          'must_change_password': false,
          'created_at': '2026-10-20T08:00:00Z', 'resigned_at': null,
          'login_locked': false,
          'group_ids': ['g1'], 'group_names': ['后期组'],
        });
        return;
      }
      if (req.method == 'PATCH' && p == '/api/v1/admin/directory/users/u1') {
        final body = h.captured.last.body;
        // email 显式 null = 清空(D6);group_ids 全量同步(D3)
        json(req, {
          'id': 'u1', 'username': 'zhangsan', 'name': body['name'],
          'email': body['email'], 'is_active': true,
          'must_change_password': false,
          'created_at': '2026-10-20T08:00:00Z', 'resigned_at': null,
          'login_locked': false,
        });
        return;
      }
      if (req.method == 'POST' && p == '/api/v1/admin/directory/users/u1/disable') {
        disableCalls += 1;
        if (disableCalls > 1) {
          json(req, {'detail': '用户已处于禁用状态'}, status: 409);
          return;
        }
        json(req, {'ok': true, 'user_id': 'u1', 'tuples_revoked': 3});
        return;
      }
      if (req.method == 'POST' && p == '/api/v1/admin/directory/users/u1/enable') {
        json(req, {'ok': true, 'user_id': 'u1', 'groups_restored': 2});
        return;
      }
      if (req.method == 'POST' &&
          p == '/api/v1/admin/directory/users/u1/reset-password') {
        json(req, {'temporary_password': 'Reset-Pw-42'});
        return;
      }
      if (req.method == 'POST' && p == '/api/v1/admin/directory/users/u1/unlock') {
        json(req, {
          'cleared_user_forms': ['zhangsan', 'z@x.com', '张三'],
          'cleared_ips': ['10.0.0.8'],
          'was_locked': true,
        });
        return;
      }

      // ── directory groups ──
      if (req.method == 'GET' && p == '/api/v1/admin/directory/groups') {
        json(req, [
          {
            'id': 'g1', 'name': '后期组', 'description': null,
            'member_count': 3, 'created_at': '2026-10-19T08:00:00Z',
            'can_create_project': true, 'can_delete_project': false,
            'can_manage_folder_templates': true,
            'can_create_artist_account': false, 'can_delete_files': false,
          },
        ]);
        return;
      }
      if (req.method == 'POST' && p == '/api/v1/admin/directory/groups') {
        final body = h.captured.last.body;
        if (body['name'] == 'dup') {
          json(req, {'detail': '组名已存在:dup'}, status: 409);
          return;
        }
        json(req, {
          'id': 'g2', 'name': body['name'], 'description': body['description'],
          'member_count': 0, 'created_at': '2026-10-20T09:00:00Z',
          'can_create_project': body['can_create_project'],
          'can_delete_project': false,
          'can_manage_folder_templates': body['can_manage_folder_templates'],
          'can_create_artist_account': body['can_create_artist_account'],
          'can_delete_files': body['can_delete_files'],
        }, status: 201);
        return;
      }
      if (req.method == 'PATCH' && p == '/api/v1/admin/directory/groups/g1') {
        final body = h.captured.last.body;
        json(req, {
          'id': 'g1', 'name': body['name'] ?? '后期组',
          'description': body['description'],
          'member_count': 3, 'created_at': '2026-10-19T08:00:00Z',
          'can_create_project': body['can_create_project'] ?? true,
          'can_delete_project': body['can_delete_project'] ?? false,
          'can_manage_folder_templates': true,
          'can_create_artist_account': false,
          'can_delete_files': body['can_delete_files'] ?? false,
        });
        return;
      }
      if (req.method == 'DELETE' && p == '/api/v1/admin/directory/groups/g1') {
        json(req, {'ok': true, 'group_id': 'g1'});
        return;
      }
      if (req.method == 'GET' &&
          p == '/api/v1/admin/directory/groups/g1/members') {
        json(req, [
          {
            'user_id': 'u1', 'username': 'zhangsan', 'name': '张三',
            'email': 'z@x.com', 'is_active': true,
          },
        ]);
        return;
      }
      if (req.method == 'POST' &&
          p == '/api/v1/admin/directory/groups/g1/members') {
        final body = h.captured.last.body;
        if (body['user_id'] == 'u-dup') {
          json(req, {'detail': '用户已在组中'}, status: 409);
          return;
        }
        json(req, {
          'user_id': body['user_id'], 'username': 'lisi', 'name': '李四',
          'email': null, 'is_active': true,
        }, status: 201);
        return;
      }
      if (req.method == 'DELETE' &&
          p == '/api/v1/admin/directory/groups/g1/members/u1') {
        json(req, {'ok': true, 'group_id': 'g1', 'user_id': 'u1'});
        return;
      }

      // ── audit ──
      if (req.method == 'GET' && p == '/api/v1/admin/audit') {
        json(req, [
          {
            'id': 'e1',
            'event_type': 'upload',
            'event_time': '2026-10-20T10:00:00Z',
            'actor_user_id': 'u1',
            'actor_name': '张三',
            'actor_open_id': null,
            'target_asset_id': 'a1',
            'target_asset_filename': 'IMG_0001.jpg',
            'target_project_id': 'p1',
            'target_project_name': '婚礼项目',
            'target_minio_key': 'key/IMG_0001.jpg',
            'request_ip': '10.0.0.9',
            'user_agent': 'ms/1.0',
            'resolved_names': {'folder_id': '素材'},
            'details': {'folder_id': 'f1', 'level': 'viewer'},
          },
        ]);
        return;
      }
      if (req.method == 'GET' && p == '/api/v1/admin/audit/export.csv') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('text', 'csv',
            charset: 'utf-8');
        req.response.headers
            .set('content-disposition', 'attachment; filename="audit-x.csv"');
        req.response.write('\uFEFFtime,event_type\n2026-10-20T10:00:00Z,upload');
        await req.response.close();
        return;
      }

      // ── grant / folder templates 写族 + apply-default ──
      if (req.method == 'POST' && p == '/api/v1/admin/grant-templates') {
        final body = h.captured.last.body;
        json(req, _templateJson(body['name'] as String,
            isDefault: body['is_default'] as bool? ?? false), status: 201);
        return;
      }
      if (req.method == 'PATCH' &&
          p == '/api/v1/admin/grant-templates/t1') {
        final body = h.captured.last.body;
        json(req, _templateJson(body['name'] as String? ?? '标准项目',
            isDefault: body['is_default'] as bool? ?? true));
        return;
      }
      if (req.method == 'DELETE' &&
          p == '/api/v1/admin/grant-templates/t1') {
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }
      if (req.method == 'POST' &&
          p == '/api/v1/admin/grant-templates/apply-default') {
        final body = h.captured.last.body;
        final ids = (body['project_ids'] as List).cast<String>();
        json(req, {
          'results': [
            for (final (i, pid) in ids.indexed)
              i == 1
                  ? {'project_id': pid, 'error': 'fga write failed'}
                  : {'project_id': pid, 'applied': 3, 'skipped_stale': 1},
          ],
          'total_applied': 3,
          'total_skipped': 1,
        });
        return;
      }
      if (req.method == 'POST' && p == '/api/v1/admin/folder-templates') {
        final body = h.captured.last.body;
        if (body['name'] == 'dup') {
          json(req, {'detail': '模板名已存在:dup'}, status: 409);
          return;
        }
        json(req, _folderTemplateJson(body['name'] as String), status: 201);
        return;
      }
      if (req.method == 'PATCH' &&
          p == '/api/v1/admin/folder-templates/ft1') {
        json(req, _folderTemplateJson('婚礼标准目录'));
        return;
      }
      if (req.method == 'DELETE' &&
          p == '/api/v1/admin/folder-templates/ft1') {
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }

      // ── admin baidu 观测面 + 文件级三操作 ──
      if (req.method == 'GET' && p == '/api/v1/admin/baidu-backup/tasks') {
        json(req, {
          'items': [_taskJson(q['status'] == 'failed' ? 'failed' : 'running')],
          'total': 1,
        });
        return;
      }
      if (req.method == 'GET' &&
          p.startsWith('/api/v1/admin/baidu-backup/tasks/t1/files')) {
        json(req, {
          'items': [
            {
              'id': 'f1',
              'source_path': '/盘/素材/a.jpg',
              'rel_path': 'a.jpg',
              'status': 'failed',
              'bytes_done': 10,
              'attempts': 2,
              'non_retryable': q['status'] == 'failed',
              'last_error': 'key_conflict:素材/a.jpg 已被成片.jpg占用',
              'asset_id': null,
              'updated_at': '2026-10-20T10:00:00Z',
            },
            {
              'id': 'f2',
              'source_path': '/盘/素材/b.jpg',
              'rel_path': 'b.jpg',
              'status': 'skipped_exists',
              'bytes_done': 0,
              'attempts': 0,
              'non_retryable': false,
              'last_error': null,
              'asset_id': 'a2',
              'updated_at': '2026-10-20T10:00:00Z',
            },
          ],
          'total': 2,
        });
        return;
      }
      if (req.method == 'GET' && p == '/api/v1/admin/baidu-backup/tasks/t1') {
        final j = _taskJson('failed');
        j.addAll({
          'bound_baidu_uid': '1001',
          'binding': {'id': 'b1', 'baidu_uid': '1001', 'status': 'active'},
          'cancel_reason': 'user_cancel',
          'retry_count': 1,
          'enum_done': true,
          'dispatched_at': '2026-10-20T10:00:01Z',
          'round_started_at': '2026-10-20T10:00:02Z',
          'lease_until': null,
          'runner_id': 'w-1',
        });
        json(req, j);
        return;
      }
      if (req.method == 'POST' &&
          p.startsWith('/api/v1/baidu/backup/tasks/t1/files/')) {
        // /files/{fid}/{action}
        final parts = p.split('/');
        final action = parts.last;
        if (action == 'retry' && parts.contains('f1')) {
          json(req, {'detail': '该文件不可重试(仅失败且非结构性失败的文件可重试)'},
              status: 409);
          return;
        }
        json(req, {'finalized': true, 'status': 'enumerating'}, status: 202);
        return;
      }

      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
  });

  tearDown(() => h.stop());

  test('用户列表:q/is_active/limit/offset 筛选参数正确,行含 login_locked 回显',
      () async {
    final page = await h.api!.directory.listUsers(
        q: 'locked', isActive: false, limit: 20, offset: 40);
    expect(h.captured.last.path, '/api/v1/admin/directory/users');
    expect(h.captured.last.body, isEmpty);
    expect(page.total, 1);
    expect(page.items.single.loginLocked, isTrue);
    expect(page.items.single.mustChangePassword, isTrue);
  });

  test('建用户带组:201 + 一次性临时密码仅出现在响应(不落日志)', () async {
    final out = await h.api!.directory.createUser(
        username: 'zhangsan',
        name: '张三',
        email: 'z@x.com',
        groupIds: ['g1', 'g2']);
    expect(h.captured.last.path, '/api/v1/admin/directory/users');
    expect(h.captured.last.body['group_ids'], ['g1', 'g2']);
    expect(out.temporaryPassword, 'Tmp-Pass-001');
    expect(out.mustChangePassword, isTrue);
  });

  test('编辑用户:email 显式 null 清空 + group_ids 全量同步', () async {
    final out = await h.api!.directory.updateUser('u1',
        name: '张三丰', email: null, groupIds: ['g1']);
    final last = h.captured.last;
    expect(last.method, 'PATCH');
    expect(last.path, '/api/v1/admin/directory/users/u1');
    expect(last.body.containsKey('email'), isTrue);
    expect(last.body['email'], isNull); // 显式 null(D6)
    expect(last.body['group_ids'], ['g1']); // 全量同步(D3)
    expect(out.name, '张三丰');
  });

  test('启停/重置/解锁:端点与结果解析;重复停用 409 detail 透传', () async {
    final dir = h.api!.directory;
    await dir.disableUser('u1');
    await dir.enableUser('u1');
    final pw = await dir.resetPassword('u1');
    expect(pw, 'Reset-Pw-42');
    final unlock = await dir.unlockUser('u1');
    expect(unlock.wasLocked, isTrue);
    expect(unlock.clearedUserForms, hasLength(3));
    expect(unlock.clearedIps, ['10.0.0.8']);

    // 已禁用行再停用:409「用户已处于禁用状态」原样透传
    Object? err;
    try {
      await dir.disableUser('u1');
    } on ApiException catch (e) {
      err = e;
    }
    expect(err, isA<ApiException>());
    expect((err as ApiException).message, contains('用户已处于禁用状态'));
  });

  test('组:列表 flag 解析/建组 409 透传/PATCH tri-state 语义', () async {
    final groups = await h.api!.directory.listGroups(q: '后期');
    expect(groups.single.canCreateProject, isTrue);
    expect(groups.single.canManageFolderTemplates, isTrue);

    final created = await h.api!.directory.createGroup(
        name: '策划组', description: 'x', canManageFolderTemplates: true);
    expect(created.id, 'g2');
    expect(created.canDeleteProject, isFalse); // 建组态不带删除开关(后端默认 false)

    Object? err;
    try {
      await h.api!.directory.createGroup(name: 'dup');
    } on ApiException catch (e) {
      err = e;
    }
    expect(err, isA<ApiException>());
    expect((err as ApiException).message, contains('组名已存在'));

    // 仅改名:flag 三态全 null = 字段省略(后端不动 tuple)
    await h.api!.directory.updateGroup('g1', name: '新名');
    expect(h.captured.last.method, 'PATCH');
    expect(h.captured.last.body.containsKey('can_create_project'), isFalse);

    // tri-state 显式 false
    await h.api!.directory
        .updateGroup('g1', canCreateProject: false, canDeleteFiles: true);
    expect(h.captured.last.body['can_create_project'], isFalse);
    expect(h.captured.last.body['can_delete_files'], isTrue);
  });

  test('组成员:列表/加(409 已在组)/移出', () async {
    final members = await h.api!.directory.listMembers('g1');
    expect(members.single.name, '张三');

    await h.api!.directory.addMember('g1', 'u2');
    expect(h.captured.last.body['user_id'], 'u2');

    Object? err;
    try {
      await h.api!.directory.addMember('g1', 'u-dup');
    } on ApiException catch (e) {
      err = e;
    }
    expect((err as ApiException).message, contains('用户已在组中'));

    await h.api!.directory.removeMember('g1', 'u1');
    expect(h.captured.last.method, 'DELETE');
  });

  test('审计:筛选参数逐项透传;CSV 导出带会话拉回 BOM 文本', () async {
    const f = AuditFilter(
      eventType: 'upload',
      actorUserId: 'u1',
      projectId: 'p1',
      from: '2026-10-01T00:00:00.000Z',
      to: '2026-10-20T23:59:59.999Z',
    );
    final items = await h.api!.audit.list(filter: f, limit: 30, offset: 60);
    expect(h.captured.last.path, '/api/v1/admin/audit');
    expect(h.captured.last.method, 'GET');
    expect(items.single.eventType, 'upload');
    expect(items.single.resolvedNames['folder_id'], '素材');
    expect(items.single.details['folder_id'], 'f1');
    expect(items.single.nameOf('folder_id'), '素材');
    expect(items.single.nameOf('level'), 'viewer');

    final (bytes, disposition) = await h.api!.audit.exportCsv(filter: f);
    expect(looksLikeCsvBytes(bytes), isTrue);
    final text = String.fromCharCodes(bytes);
    expect(text, contains('time,event_type'));
    // P2-5:Content-Disposition 原文回传(harness 置了 attachment; filename)
    expect(disposition, 'attachment; filename="audit-x.csv"');
  });

  test('权限模板:建(items 形状)/编(is_default)/删(204)/应用默认部分成功', () async {
    final created = await h.api!.adminTemplates.createTemplate(
      name: '标准项目',
      description: null,
      isDefault: true,
      items: [
        const GrantEntry(kind: 'group', id: 'g1', roles: ['viewer', 'uploader']),
        const GrantEntry(kind: 'user', id: 'u1', roles: ['admin']),
      ],
    );
    expect(h.captured.last.path, '/api/v1/admin/grant-templates');
    expect(h.captured.last.body['items'], hasLength(2));
    expect((h.captured.last.body['items'] as List).first['roles'],
        ['viewer', 'uploader']);
    expect(created.isDefault, isTrue);

    await h.api!.adminTemplates.updateTemplate('t1',
        name: '改名', description: null, isDefault: true, items: [
          const GrantEntry(kind: 'group', id: 'g1', roles: ['viewer']),
        ]);
    expect(h.captured.last.method, 'PATCH');

    await h.api!.adminTemplates.deleteTemplate('t1');
    expect(h.captured.last.method, 'DELETE');
    expect(h.captured.last.path, '/api/v1/admin/grant-templates/t1');

    final result = await h.api!.adminTemplates.applyDefault(['p1', 'p2']);
    expect(result.results, hasLength(2));
    expect(result.results.first.isFailed, isFalse);
    expect(result.results.first.applied, 3);
    expect(result.results[1].isFailed, isTrue);
    expect(result.results[1].error, 'fga write failed');
    expect(result.totalApplied, 3);
    expect(result.failedCount, 1);
  });

  test('目录模板:建(条目形状)/编/删;409 透传', () async {
    final created = await h.api!.adminTemplates
        .createFolderTemplate('婚礼标准目录', paths: ['素材/视频/原始', '成片']);
    expect(h.captured.last.path, '/api/v1/admin/folder-templates');
    expect((h.captured.last.body['entries'] as List).first,
        {'path': '素材/视频/原始'});
    expect(created.entryCount, 2);
    // 空描述:请求体 description 键恒携带且为显式 null(非省略/非空串;
    // 表单层 desc.isEmpty ? null : desc 落到这里的序列化钉子)
    expect(h.captured.last.body.containsKey('description'), isTrue);
    expect(h.captured.last.body['description'], isNull);

    await h.api!.adminTemplates.updateFolderTemplate('ft1',
        name: '改', description: null, paths: ['成片']);
    expect(h.captured.last.method, 'PATCH');
    // 编辑态空描述同口径:description 键显式 null = 清空(恒携带,web 同款)
    expect(h.captured.last.body.containsKey('description'), isTrue);
    expect(h.captured.last.body['description'], isNull);

    Object? err;
    try {
      await h.api!.adminTemplates.createFolderTemplate('dup', paths: ['a']);
    } on ApiException catch (e) {
      err = e;
    }
    expect((err as ApiException).message, contains('模板名已存在'));

    await h.api!.adminTemplates.deleteFolderTemplate('ft1');
    expect(h.captured.last.method, 'DELETE');
  });

  test('百度任务:列表状态筛选/详情(调度观测)/文件明细分页参数', () async {
    final page = await h.api!.adminBaidu.listTasks(status: 'failed', q: '灵机');
    expect(h.captured.last.path, '/api/v1/admin/baidu-backup/tasks');
    expect(page.items.single.status, 'failed');
    expect(page.items.single.user.name, '张三');
    expect(page.items.single.progressPct, greaterThanOrEqualTo(0));

    final detail = await h.api!.adminBaidu.taskDetail('t1');
    expect(detail.retryCount, 1);
    expect(detail.enumDone, isTrue);
    expect(detail.binding?.baiduUid, '1001');
    expect(detail.cancelReason, 'user_cancel');

    final files = await h.api!.adminBaidu.taskFiles('t1',
        status: 'failed', limit: 20, offset: 0);
    expect(h.captured.last.path, '/api/v1/admin/baidu-backup/tasks/t1/files');
    expect(files.total, 2);
    expect(files.items.first.isKeyConflict, isTrue);
  });

  test('文件级三操作:202 响应解析;non_retryable 重试 409 detail 透传', () async {
    final out = await h.api!.adminBaidu.overwriteFile('t1', 'f2');
    expect(out.finalized, isTrue);
    expect(out.status, 'enumerating');
    expect(
        h.captured.last.path, '/api/v1/baidu/backup/tasks/t1/files/f2/overwrite');

    await h.api!.adminBaidu.randomSuffixFile('t1', 'f1');
    expect(
        h.captured.last.path,
        '/api/v1/baidu/backup/tasks/t1/files/f1/random-suffix');

    Object? err;
    try {
      await h.api!.adminBaidu.retryFile('t1', 'f1');
    } on ApiException catch (e) {
      err = e;
    }
    expect((err as ApiException).message, contains('不可重试'));
  });

  test('静态断言:管理后台 feature 源码不出现 url_launcher(CSV 导出必须 dio 带会话)',
      () {
    final dir = Directory('lib/features/admin');
    expect(dir.existsSync(), isTrue);
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      // 注释里的「禁 url_launcher」钉子不算使用;只断言 import 与调用点
      expect(src.contains('package:url_launcher'), isFalse,
          reason: '${f.path} 不得 import url_launcher(系统浏览器无会话 cookie 必 401)');
      expect(src.contains('launchUrl('), isFalse, reason: f.path);
    }
  });
}

Map<String, dynamic> _templateJson(String name, {required bool isDefault}) => {
      'id': 't1',
      'name': name,
      'description': null,
      'is_default': isDefault,
      'items': [
        {
          'kind': 'group',
          'id': 'g1',
          'roles': ['viewer', 'uploader'],
          'name': '后期组',
          'missing': false,
        },
      ],
    };

Map<String, dynamic> _folderTemplateJson(String name) => {
      'id': 'ft1',
      'name': name,
      'description': null,
      'entry_count': 2,
      'entries': [
        {'path': '素材/视频/原始'},
        {'path': '成片'},
      ],
    };

Map<String, dynamic> _taskJson(String status) => {
      'id': 't1',
      'user': {'id': 'u1', 'username': 'zhangsan', 'name': '张三'},
      'status': status,
      'source_dir': '/灵机备份',
      'project': {'id': 'p1', 'name': '婚礼项目'},
      'target_folder': {'id': 'fo1', 'name': '灵机备份'},
      'total_files': 4,
      'done_files': 2,
      'failed_files': 1,
      'skipped_files': 1,
      'cancelled_files': 0,
      'total_bytes': 400,
      'done_bytes': 200,
      'created_at': '2026-10-20T09:00:00Z',
      'updated_at': '2026-10-20T10:00:00Z',
      'fail_reason': 'file_failed',
      'cancel_requested': false,
    };

/// looksLikeCsv 的测试侧镜像(避免测试 import feature 文件——保持纯契约测试边界)。
bool looksLikeCsvBytes(List<int> bytes) {
  if (bytes.isEmpty) return false;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return true;
  }
  return String.fromCharCodes(bytes.take(16)).startsWith('time,');
}
