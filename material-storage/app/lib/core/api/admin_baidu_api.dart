/// AdminBaiduApi — 百度备份 admin 观测面 + 文件级三操作薄封装(B8;admin.py
/// baidu-backup admin 族与 baidu_backup.py 用户侧文件级三端点实码):
/// - 列表(status 白名单/q 模糊用户名姓名源目录)/详情(调度观测)/文件明细分页;
/// - retry/overwrite/random-suffix 挂在**用户侧** /api/v1/baidu/backup/tasks/
///   {id}/files/{fid}/*(后端 _own_task 守门,admin 仅对本人任务可操作,他人
///   任务 404 detail 原样透传——后端无 admin 文件级端点,需求 §7 处置手册语义
///   按用户侧三端点接入)。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class AdminBaiduApi {
  AdminBaiduApi(this._api);

  final MsApi _api;

  /// GET /admin/baidu-backup/tasks — 全系统任务列表(status 非白名单 400)。
  Future<AdminBaiduTasksPage> listTasks({
    String? status,
    String q = '',
    int limit = 20,
    int offset = 0,
  }) async {
    final r = await _api.http.get('/api/v1/admin/baidu-backup/tasks',
        queryParameters: {
          if (status != null && status.isNotEmpty) 'status': status,
          if (q.isNotEmpty) 'q': q,
          'limit': limit,
          'offset': offset,
        });
    if (r.statusCode != 200) throw _api.err(r, '备份任务加载失败');
    return AdminBaiduTasksPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// GET /admin/baidu-backup/tasks/{id} — 详情(+调度观测字段/绑定行)。
  Future<AdminBaiduTaskDetail> taskDetail(String taskId) async {
    final r =
        await _api.http.get('/api/v1/admin/baidu-backup/tasks/$taskId');
    if (r.statusCode != 200) throw _api.err(r, '任务详情加载失败');
    return AdminBaiduTaskDetail.fromJson(r.data as Map<String, dynamic>);
  }

  /// GET /admin/baidu-backup/tasks/{id}/files — 文件明细分页(status 行级筛选)。
  Future<AdminBaiduTaskFilesPage> taskFiles(
    String taskId, {
    String? status,
    int limit = 20,
    int offset = 0,
  }) async {
    final r = await _api.http
        .get('/api/v1/admin/baidu-backup/tasks/$taskId/files', queryParameters: {
      if (status != null && status.isNotEmpty) 'status': status,
      'limit': limit,
      'offset': offset,
    });
    if (r.statusCode != 200) throw _api.err(r, '文件明细加载失败');
    return AdminBaiduTaskFilesPage.fromJson(r.data as Map<String, dynamic>);
  }

  // ── 文件级三操作(用户侧端点;见文件头说明)──────────────────────────────

  /// POST /backup/tasks/{id}/files/{fid}/retry — 单文件重试(non_retryable 行
  /// 后端 409;任务须 failed;UI 侧 non_retryable 置灰)。
  Future<BaiduReviveOut> retryFile(String taskId, String fileId) =>
      _fileOp(taskId, fileId, 'retry');

  /// POST .../overwrite — 覆盖导入(skipped_exists 或 key_conflict 失败行;
  /// 清除-再导入,需对占用者有管理权限)。
  Future<BaiduReviveOut> overwriteFile(String taskId, String fileId) =>
      _fileOp(taskId, fileId, 'overwrite');

  /// POST .../random-suffix — 随机后缀导入(key_conflict 失败行的出路;
  /// 网盘原文件名不变,存储 key 换不冲突后缀)。
  Future<BaiduReviveOut> randomSuffixFile(String taskId, String fileId) =>
      _fileOp(taskId, fileId, 'random-suffix');

  Future<BaiduReviveOut> _fileOp(
      String taskId, String fileId, String action) async {
    final r = await _api.http.post(
        '/api/v1/baidu/backup/tasks/$taskId/files/$fileId/$action');
    if (r.statusCode != 202) throw _api.err(r, '操作失败');
    return BaiduReviveOut.fromJson(r.data as Map<String, dynamic>);
  }
}
