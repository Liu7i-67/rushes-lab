/// B8 管理后台纯逻辑单测:百度文件级三操作处置手册(fileActionPlan 分流/
/// non_retryable 置灰/key_conflict 占用者解析)、目录模板路径校验(=web 实况)、
/// CSV 导出落盘(落盘矩阵 other 列 + 文件名/嗅探)、入口闸门(Me flag 回落)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/admin/baidu_file_actions.dart';
import 'package:ms_app/features/admin/folder_template_form_sheet.dart'
    show
        dedupNodeCount,
        folderTemplatePathError,
        pathsToTreeRows;
import 'package:ms_app/features/admin/audit_export.dart';
import 'package:ms_app/models/models.dart';
import 'package:ms_app/services/media_save.dart';

AdminBaiduTask taskOf(String status) => AdminBaiduTask(
      id: 't1',
      user: AdminTaskUser(id: 'u1', username: 'zs', name: '张三'),
      status: status,
      sourceDir: '/灵机备份',
      project: AdminTaskRef(id: 'p1', name: '婚礼项目'),
      createdAt: '2026-10-20T09:00:00Z',
      updatedAt: '2026-10-20T10:00:00Z',
    );

AdminBaiduTaskFile fileOf(
    {required String status, bool nonRetryable = false, String? lastError}) {
  final f = AdminBaiduTaskFile(
    id: 'f1',
    sourcePath: '/盘/a.jpg',
    relPath: 'a.jpg',
    status: status,
    nonRetryable: nonRetryable,
    lastError: lastError,
    updatedAt: '2026-10-20T10:00:00Z',
  );
  return f;
}

void main() {
  group('百度文件级三操作处置手册(fileActionPlan/key_conflict 分流)', () {
    test('failed 任务的普通失败行:可重试;non_retryable 置灰语义由 UI 层消费', () {
      final task = taskOf('failed');
      final row = fileOf(status: 'failed');
      final plan = fileActionPlan(task, row);
      expect(plan.canRetry, isTrue);
      expect(plan.canOverwrite, isFalse);
      expect(plan.canResolveConflict, isFalse);
    });

    test('non_retryable 行仍 canRetry=true,UI 据此渲染置灰 + 结构性失败提示', () {
      final task = taskOf('failed');
      final row = fileOf(status: 'failed', nonRetryable: true);
      final plan = fileActionPlan(task, row);
      expect(plan.canRetry, isTrue); // 置灰判定在 UI:nonRetryable → disabled
      expect(kNonRetryableTip, contains('结构性失败'));
    });

    test('key_conflict 失败行分流:不出现普通重试,改出 覆盖导入+随机后缀', () {
      final task = taskOf('failed');
      final row = fileOf(
          status: 'failed',
          lastError: 'key_conflict:素材/a.jpg 已被 成片.jpg、b.jpg占用');
      final plan = fileActionPlan(task, row);
      expect(plan.canRetry, isFalse);
      expect(plan.canResolveConflict, isTrue);
      expect(plan.canOverwrite, isFalse);
    });

    test('completed 任务的 skipped_exists 行:仅覆盖导入;running 任务无操作', () {
      final done = fileActionPlan(
          taskOf('completed'), fileOf(status: 'skipped_exists'));
      expect(done.canOverwrite, isTrue);
      expect(done.canRetry, isFalse);

      final running =
          fileActionPlan(taskOf('running'), fileOf(status: 'skipped_exists'));
      expect(running.hasAny, isFalse);
    });

    test('keyConflictHolders:F1 格式解析占用者,解析失败回 null', () {
      expect(
          keyConflictHolders('key_conflict:素材/a.jpg 已被 成片.jpg、b.jpg占用'),
          ['成片.jpg', 'b.jpg']);
      expect(keyConflictHolders('key_conflict:x 已被 a.jpg占用'), ['a.jpg']);
      expect(keyConflictHolders('格式不对'), isNull);
      expect(keyConflictHolders(null), isNull);
    });

    test('确认文案:key_conflict 点名占用者;skipped 行通用文案', () {
      final conflict = fileOf(
          status: 'failed',
          lastError: 'key_conflict:素材/a.jpg 已被 成片.jpg占用');
      final (t1, c1) =
          confirmText(conflict, fileActionPlan(taskOf('failed'), conflict));
      expect(t1, '覆盖导入?');
      expect(c1, contains('成片.jpg'));

      final skipped = fileOf(status: 'skipped_exists');
      final (_, c2) =
          confirmText(skipped, fileActionPlan(taskOf('failed'), skipped));
      expect(c2, contains('永久删除目标位置的原文件后重新导入'));
    });
  });

  group('目录模板路径校验(web pathErrorOf 同款;后端仍复检 422)', () {
    test('非法路径逐条命中', () {
      expect(folderTemplatePathError(''), '路径为空');
      expect(folderTemplatePathError('/素材'), '不能以 / 开头或结尾');
      expect(folderTemplatePathError('素材/'), '不能以 / 开头或结尾');
      expect(folderTemplatePathError('素材//成片'), '含空段(连续 //)');
      expect(folderTemplatePathError('a/b/c/d/e/f/g/h/i/j/k'), '层级超 10 段');
      expect(folderTemplatePathError('素材/../成片'), '段「..」非法');
      expect(folderTemplatePathError('素材/.成片'), isNull); // `.成片` 合法段
      expect(folderTemplatePathError(r'素材\成片'), '段不能含反斜杠 \\');
      expect(folderTemplatePathError('素材 /成片'), '段「素材 」首尾含空白');
      expect(folderTemplatePathError('x' * 256), '单段超 255 字符');
      expect(folderTemplatePathError('${'a' * 201}/${'b' * 201}/${'c' * 201}'),
          '总长超 600 字符');
    });

    test('合法路径(中文/多段)通过', () {
      expect(folderTemplatePathError('素材/视频/原始'), isNull);
      expect(folderTemplatePathError('婚礼成片 2026'), isNull);
    });

    test('树预览:paths 展开去重计数(与后端规则 7 同口径)', () {
      final rows = pathsToTreeRows(['素材/视频', '素材/成片', '成片']);
      expect(rows.map((r) => r.$2), ['素材', '视频', '成片', '成片']);
      // '素材'与'成片'首段各计一次,重复段不重复计
      expect(dedupNodeCount(['素材/视频', '素材/成片', '成片']), 4);
    });
  });

  group('审计 CSV 导出落盘(禁 url_launcher;dio 带会话由 AuditApi 承担)', () {
    test('落盘矩阵 other 列:Android→Downloads / iOS→share(注入假件验证)',
        () async {
      final calls = <String>[];
      final dir = await Directory.systemTemp.createTemp('b8_export');
      // Windows 并发跑批下,目录删除与 saveExportedCsv finally 内的 f.delete()
      // 存在句柄释放竞态 → 容错清理(临时目录本就随系统回收)
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      Future<SinkOutcome> ok(String where) async {
        calls.add(where);
        return SinkOutcome.ok(where);
      }

      final savers = PlatformSavers(
        gallery: (f, a) async => SinkOutcome.fail('no'),
        downloads: (f) => ok('downloads'),
        share: (f) => ok('share'),
      );
      final bytes = utf8.encode('\uFEFFtime,event_type\n2026,a');
      final android = await saveExportedCsv(bytes, 'audit-a.csv',
          platform: SavePlatform.android,
          savers: savers,
          tempRoot: () async => dir);
      expect(calls, ['downloads']);
      expect(android, contains('Download/浣花视界'));

      calls.clear();
      await saveExportedCsv(bytes, 'audit-i.csv',
          platform: SavePlatform.ios,
          savers: savers,
          tempRoot: () async => dir);
      expect(calls, ['share']);
    });

    test('文件名解析与 CSV 嗅探(BOM/表头;错误体不误存)', () {
      final name = csvFilenameFromDisposition(
          'attachment; filename="audit-20261020-120000.csv"', DateTime.now());
      expect(name, 'audit-20261020-120000.csv');
      expect(csvFilenameFromDisposition(null, DateTime(2026, 10, 20, 9, 5, 3)),
          'audit-20261020-090503.csv');
      expect(looksLikeCsv(utf8.encode('\uFEFFtime,event_type')), isTrue);
      expect(looksLikeCsv(utf8.encode('time,event_type')), isTrue);
      expect(looksLikeCsv(utf8.encode('{"detail":"x"}')), isFalse);
    });
  });

  group('入口闸门(功能点 1/7:双闸门语义)', () {
    test('Me.is_folder_template_manager 缺省回落 is_system_admin(旧后端兼容)',
        () {
      final admin = Me.fromJson({
        'id': 'u1',
        'name': '管理员',
        'is_system_admin': true,
      });
      expect(admin.isFolderTemplateManager, isTrue); // ?? is_system_admin

      final plain = Me.fromJson({
        'id': 'u2',
        'name': '成员',
        'is_system_admin': false,
        'is_folder_template_manager': false,
      });
      expect(plain.isFolderTemplateManager, isFalse);
    });

    test('持组 flag 非 admin:isFolderTemplateManager=true 但 isSystemAdmin=false'
        '(我的页仅见目录模板入口,管理后台不可见)', () {
      final flagOnly = Me.fromJson({
        'id': 'u3',
        'name': '模板管理员',
        'is_system_admin': false,
        'is_folder_template_manager': true,
      });
      expect(flagOnly.isFolderTemplateManager, isTrue);
      expect(flagOnly.isSystemAdmin, isFalse);
    });
  });

  test('百度任务模型:进度口径 =(done+skipped+cancelled)/total;空 completed=100;'
      'enumerating 不渲染(列表侧 Pct 值仍可算,UI 按 status 短路)', () {
    final t = _task(4, 2, 1, 1);
    expect(t.progressPct, 75); // (done2+skipped1)/4
    expect(_task(0, 0, 0, 0, 'enumerating').progressPct, 0);
    expect(_task(0, 0, 0, 0, 'completed').progressPct, 100); // 空目录(web taskPct 同款)
    expect(_task(0, 0, 0, 0, 'cancelled').progressPct, 0); // 非空目录 completed 外仍 0
    expect(taskOf('running').isActive, isTrue);
    expect(taskOf('failed').isActive, isFalse);
  });

  test('文件级三操作归属者闸门(P2-4):仅任务归属者可操作,未登录/他人一律拒绝', () {
    final task = taskOf('failed'); // user.id = u1
    expect(fileOpsAllowed(task, 'u1'), isTrue);
    expect(fileOpsAllowed(task, 'u2'), isFalse);
    expect(fileOpsAllowed(task, null), isFalse); // me 未加载兜底
  });

  test('GrantTemplateItem:missing 透传(P2-3;已删主体行渲染 amber「已删除」)', () {
    final deleted = GrantTemplateItem.fromJson({
      'kind': 'group',
      'id': 'g9',
      'roles': ['viewer'],
      'name': '',
      'missing': true,
    });
    expect(deleted.missing, isTrue);
    final alive = GrantTemplateItem.fromJson({
      'kind': 'user',
      'id': 'u1',
      'roles': ['viewer'],
      'name': '张三',
    });
    expect(alive.missing, isFalse); // 缺省 false
  });
}

AdminBaiduTask _task(
    [int total = 0,
    int done = 0,
    int failed = 0,
    int skipped = 0,
    String status = 'completed']) {
  final f = AdminBaiduTask.fromJson({
    'id': 't1',
    'user': {'id': 'u1', 'username': null, 'name': '张三'},
    'status': status,
    'source_dir': '/x',
    'project': {'id': 'p1', 'name': '项目'},
    'target_folder': null,
    'total_files': total,
    'done_files': done,
    'failed_files': failed,
    'skipped_files': skipped,
    'cancelled_files': 0,
    'total_bytes': 0,
    'done_bytes': 0,
    'created_at': '2026-10-20T09:00:00Z',
    'updated_at': '2026-10-20T10:00:00Z',
    'fail_reason': null,
    'cancel_requested': false,
  });
  return f;
}
