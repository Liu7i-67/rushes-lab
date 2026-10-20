/// B5 端点 wire 级契约单测(plain test(),本地 HttpServer 可真实推进 IO;
/// widget 测试禁真实 socket,UI 编排见 features/*_test)。契约以
/// api/app/routers/{share,assets,approvals}.py + models/__init__.py 实码为准:
/// share requires_login 恒 true / meta 单条不传 labels_mode / batch 入参 /
/// approvals access 不携 duration_seconds / trash query 参数 / restore 204。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/models/models.dart';

import '../helpers/api_harness.dart';

void main() {
  test('PATCH /assets/{id}/meta:labels_mode 显式传/不传两态 + user_labels/notes', () async {
    final h = ApiHarness((req) async {
      if (req.method == 'PATCH' && req.uri.path == '/api/v1/assets/a1/meta') {
        json(req, {
          'id': 'a1', 'folder_id': 'f1', 'filename': 'a.jpg',
          'minio_bucket': 'b', 'minio_key': 'k', 'etag': null,
          'minio_version_id': null, 'size_bytes': 1,
          'content_type': 'image/jpeg', 'created_at': '2026-10-20T10:00:00Z',
          'user_labels': ['x'], 'notes': 'n',
        });
        return;
      }
      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
    addTearDown(h.stop);
    final api = h.api!;

    // 批量 merge:显式传 labels_mode
    await api.ops.updateMeta('a1',
        userLabels: ['x'], notes: 'n', labelsMode: 'merge');
    // 单条编辑:不传 labels_mode(后端默认 replace)
    await api.ops.updateMeta('a1', notes: '');
    // 显式清空标签:空数组照传(显式传空=清空,后端语义)
    await api.ops.updateMeta('a1', userLabels: const []);

    expect(h.captured, hasLength(3));
    expect(h.captured[0].body,
        {'user_labels': ['x'], 'notes': 'n', 'labels_mode': 'merge'});
    expect(h.captured[1].body.containsKey('labels_mode'), isFalse,
        reason: '单条不传 labels_mode(web 实况)');
    expect(h.captured[1].body, {'notes': ''});
    expect(h.captured[2].body, {
      'user_labels': <String>[],
    });
  });

  test('POST /assets/batch-prefix:asset_ids/action/prefix 入参契约', () async {
    final h = ApiHarness((req) async {
      if (req.method == 'POST' && req.uri.path == '/api/v1/assets/batch-prefix') {
        json(req, {
          'renamed': 1,
          'skipped': 1,
          'skipped_reasons': {'already_prefixed': 1},
        });
        return;
      }
      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
    addTearDown(h.stop);
    final r = await h.api!.ops.batchPrefix(['a1', 'a2'],
        action: 'add', prefix: 'p-');
    expect(h.captured.single.body,
        {'asset_ids': ['a1', 'a2'], 'action': 'add', 'prefix': 'p-'});
    expect(r.renamed, 1);
    expect(r.skipped, 1);
    expect(r.skippedReasons, {'already_prefixed': 1});
    expect(AssetBatchPrefixResult.reasonLabel('already_prefixed'), '已带该前缀');
    expect(AssetBatchPrefixResult.reasonLabel('unknown_key'), 'unknown_key',
        reason: '未知键回落 raw');
  });

  test('POST /assets/batch-move:target_folder_id 入参 + skipped/fga_pending 出参',
      () async {
    final h = ApiHarness((req) async {
      if (req.method == 'POST' && req.uri.path == '/api/v1/assets/batch-move') {
        json(req, {
          'moved_count': 1,
          'skipped': [
            {'asset_id': 'a2', 'reason': 'duplicate_location'},
          ],
          'fga_pending': ['a3'],
        });
        return;
      }
      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
    addTearDown(h.stop);
    final r = await h.api!.ops.batchMove(['a1', 'a2', 'a3'],
        targetFolderId: 'f2');
    expect(h.captured.single.body,
        {'asset_ids': ['a1', 'a2', 'a3'], 'target_folder_id': 'f2'});
    expect(r.movedCount, 1);
    expect(r.skipped.single.assetId, 'a2');
    expect(AssetBatchMoveSkip.reasonLabel('duplicate_location'), '已在目标位置');
    expect(AssetBatchMoveSkip.reasonLabel('weird'), 'weird');
    expect(r.fgaPending, ['a3']);
  });

  test('POST /share/assets/{id}:expires_in_seconds + requires_login 恒 true;'
      'ShareCreateOut 三字段', () async {
    final h = ApiHarness((req) async {
      if (req.method == 'POST' && req.uri.path == '/api/v1/share/assets/a1') {
        json(req, {
          'token': 'tok',
          'landing_url': 'https://ms.test/s/tok',
          'expires_at': '2026-10-30T10:00:00',
        });
        return;
      }
      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
    addTearDown(h.stop);
    final link = await h.api!.share.shareAsset('a1', expiresInSeconds: 3600);
    expect(h.captured.single.body, {
      'expires_in_seconds': 3600,
      'requires_login': true, // 恒 true(web 硬编码;无提取码/下载开关字段)
    });
    expect(link.token, 'tok');
    expect(link.landingUrl, 'https://ms.test/s/tok');
    expect(link.expiresAt, '2026-10-30T10:00:00');
  });

  test('POST /approvals:download 携 duration_seconds;access 不携(键省略);'
      '422 detail 数组透传', () async {
    ApiHarness? harness; // 闭包回指(捕获列表在构造期尚不可用)
    final h = ApiHarness((req) async {
      if (req.method == 'POST' && req.uri.path == '/api/v1/approvals') {
        // capture 已消费 body 流:分支读 captured.last,勿再 readJson
        if (harness?.captured.last.body['action'] == 'bad') {
          json(req, {
            'detail': [
              {'loc': ['body', 'reason'], 'msg': 'min length'},
            ],
          }, status: 422);
          return;
        }
        json(req, {'id': 'ap1'}, status: 201);
        return;
      }
      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    harness = h;
    await h.start();
    addTearDown(h.stop);
    final api = h.api!;

    await api.approvals.create(
        targetType: 'asset', targetId: 'a1', action: 'download',
        durationSeconds: 3600, reason: '理由足够长');
    expect(h.captured[0].body, {
      'target_type': 'asset',
      'target_id': 'a1',
      'action': 'download',
      'duration_seconds': 3600,
      'reason': '理由足够长',
    });

    await api.approvals.create(
        targetType: 'sensitive_folder', targetId: 'sf1', action: 'access',
        reason: '理由足够长');
    expect(h.captured[1].body.containsKey('duration_seconds'), isFalse,
        reason: 'access=永久,键省略(后端 None=永久)');

    try {
      await api.approvals.create(
          targetType: 'asset', targetId: 'a1', action: 'bad',
          durationSeconds: 60, reason: '理由足够长');
      fail('should throw');
    } catch (e) {
      expect('$e', contains('body.reason: min length'),
          reason: 'extractDetail 数组型渲染 loc: msg');
    }
  });

  test('GET /assets/trash:folder_id/limit/offset query + TrashOut;restore 204', () async {
    final h = ApiHarness((req) async {
      if (req.method == 'GET' && req.uri.path == '/api/v1/assets/trash') {
        expect(req.uri.queryParameters['folder_id'], 'f1');
        expect(req.uri.queryParameters['limit'], '500');
        expect(req.uri.queryParameters['offset'], '0');
        json(req, {'items': <Object?>[], 'total': 7});
        return;
      }
      if (req.method == 'POST' && req.uri.path == '/api/v1/assets/a1/restore') {
        noContent(req);
        return;
      }
      json(req, {'detail': 'not found'}, status: 404);
    }, capture: true);
    await h.start();
    addTearDown(h.stop);
    final page = await h.api!.ops.listTrash('f1');
    expect(page.total, 7);
    await h.api!.ops.restore('a1');
    // record 含 Map 字段:== 走字段恒等,勿整 record 比较(空 Map 非结构相等)
    expect(h.captured.last.method, 'POST');
    expect(h.captured.last.path, '/api/v1/assets/a1/restore');
    expect(h.captured.last.body, isEmpty);
  });
}
