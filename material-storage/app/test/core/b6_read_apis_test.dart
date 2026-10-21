/// users / admin 模板读端点契约单测(B6):users 简表搜、groups 简表、
/// username-available 预检解析、grant-templates/folder-templates 出参解析
/// (items 主体名/missing、entries/entry_count)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';

import '../helpers/api_harness.dart';

void main() {
  late ApiHarness h;

  setUp(() async {
    h = ApiHarness((req) async {
      if (req.uri.path == '/api/v1/users') {
        json(req, [
          {'id': 'u1', 'username': 'jia', 'name': '甲', 'email': 'j@x.com'},
        ]);
        return;
      }
      if (req.uri.path == '/api/v1/users/username-available') {
        json(req, {'available': req.uri.queryParameters['username'] != 'taken'});
        return;
      }
      if (req.uri.path == '/api/v1/groups') {
        json(req, [
          {'id': 'g1', 'name': '后期组', 'description': null, 'member_count': 5},
        ]);
        return;
      }
      if (req.uri.path == '/api/v1/admin/grant-templates') {
        json(req, [
          {
            'id': 't1',
            'name': '标准项目',
            'description': 'viewer+uploader',
            'is_default': true,
            'items': [
              {
                'kind': 'group',
                'id': 'g1',
                'roles': ['viewer', 'uploader'],
                'name': '后期组',
                'missing': false,
              },
              {
                'kind': 'user',
                'id': 'u9',
                'roles': ['viewer'],
                'name': 'u9',
                'missing': true,
              },
            ],
          }
        ]);
        return;
      }
      if (req.uri.path == '/api/v1/admin/folder-templates') {
        json(req, [
          {
            'id': 'ft1',
            'name': '婚礼标准目录',
            'description': null,
            'entry_count': 2,
            'entries': [
              {'path': '素材/视频/原始'},
              {'path': '成片'},
            ],
          }
        ]);
        return;
      }
      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
  });

  tearDown(() => h.stop());

  test('searchUsers:q/limit 透传 + UserBrief 解析', () async {
    final users = await h.api!.users.searchUsers(q: '甲', limit: 20);
    expect(users.single.name, '甲');
    expect(users.single.username, 'jia');
  });

  test('searchGroups:member_count 解析', () async {
    final groups = await h.api!.users.searchGroups(q: '后期');
    expect(groups.single.memberCount, 5);
  });

  test('usernameAvailable:available 布尔解析;403 透传 ApiException', () async {
    expect(await h.api!.users.usernameAvailable('free'), isTrue);
    expect(await h.api!.users.usernameAvailable('taken'), isFalse);

    final h403 = ApiHarness((req) async {
      json(req, {'detail': 'not allowed'}, status: 403);
    });
    await h403.start();
    try {
      await h403.api!.users.usernameAvailable('x');
      fail('应抛 403');
    } on ApiException catch (e) {
      expect(e.status, 403);
    } finally {
      await h403.stop();
    }
  });

  test('grantTemplates:items 含角色/主体名/missing', () async {
    final templates = await h.api!.adminTemplates.grantTemplates();
    expect(templates.single.isDefault, isTrue);
    expect(templates.single.items[0].name, '后期组');
    expect(templates.single.items[0].roles, ['viewer', 'uploader']);
    expect(templates.single.items[1].missing, isTrue,
        reason: '主体已删标 missing,行上要显式提示(提交被 400 拦)');
  });

  test('folderTemplates:entries/entry_count 解析', () async {
    final templates = await h.api!.adminTemplates.folderTemplates();
    expect(templates.single.entryCount, 2);
    expect(templates.single.entries.map((e) => e.path),
        ['素材/视频/原始', '成片']);
  });
}
