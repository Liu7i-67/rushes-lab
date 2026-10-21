/// BaiduApi — /api/v1/baidu/backup 族薄封装(契约对齐
/// api/app/routers/baidu_backup.py 实码):B0① binding 三端点;B9 §8.10
/// 用户侧全量(netdisk folders 懒加载/tasks 列表详情/cancel/retry-failed/
/// 删除/解绑/文件三操作)。端点统一经 MsApi.guard5xx 包装(§4.1 中文 detail
/// 透传;B9 起 validateStatus 全放行,5xx 亦回 Response 走 `_api.err` 路径)。
///
/// 脱敏红线(§13):authorize-url 返回的 url(含 client_id/state 等 query)与
/// binding 请求体里的授权 code 只存在于响应/请求体,Dio 日志拦截器只记 host+path;
/// 本文件与调用侧新增日志时同样禁止记录 url 全文与 code。
library;

import '../../models/models.dart';
import 'ms_api.dart';

class BaiduApi {
  BaiduApi(this._api);

  final MsApi _api;

  /// GET /backup/binding → 绑定状态;404=功能开关关闭(baidu_backup_enabled=false,
  /// 后端统一 404)→ 返回 null,调用方按「未启用」处理。
  Future<BaiduBindingInfo?> bindingStatus() async {
    final r = await _api.guard5xx(
        _api.http.get('/api/v1/baidu/backup/binding'), '查询绑定状态失败');
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw _api.err(r, '查询绑定状态失败');
    return BaiduBindingInfo.fromJson(r.data as Map<String, dynamic>);
  }

  /// POST /backup/binding/authorize-url → oob 授权链接。
  /// 404=未启用;503=服务端百度凭证未配置(detail 透传)。
  Future<String> authorizeUrl() async {
    final r = await _api.guard5xx(
        _api.http.post('/api/v1/baidu/backup/binding/authorize-url'),
        '生成授权链接失败');
    if (r.statusCode == 404) throw ApiException(404, '网盘备份未启用');
    if (r.statusCode != 200) throw _api.err(r, '生成授权链接失败');
    return (r.data as Map<String, dynamic>)['url'] as String;
  }

  /// POST /backup/binding {code} → 授权码换 token 落库。
  /// 400=授权码无效或已过期(单次有效约 10 分钟);429=限频;
  /// 502=获取百度账号信息失败;503=凭证未配置;detail 均透传。
  Future<BaiduBindingInfo> bind(String code) async {
    final r = await _api.guard5xx(
        _api.http.post('/api/v1/baidu/backup/binding', data: {'code': code}),
        '绑定失败');
    if (r.statusCode == 404) throw ApiException(404, '网盘备份未启用');
    if (r.statusCode != 200) throw _api.err(r, '绑定失败');
    return BaiduBindingInfo.fromJson(r.data as Map<String, dynamic>);
  }

  /// DELETE /backup/binding → 软解绑(取消名下活动中任务+作废断点);
  /// 404=尚未绑定(detail 透传「尚未绑定百度网盘账号」)。
  Future<void> unbind() async {
    final r = await _api.guard5xx(
        _api.http.delete('/api/v1/baidu/backup/binding'), '解绑失败');
    if (r.statusCode == 404) throw ApiException(404, '尚未绑定百度网盘账号');
    if (r.statusCode != 204 && r.statusCode != 200) {
      throw _api.err(r, '解绑失败');
    }
  }

  // ── 网盘目录浏览(懒加载;B9 §8.10)─────────────────────────────────────

  /// GET /backup/netdisk/folders?path= — 目录树懒加载(返回子目录+文件全条目,
  /// 目录前文件后;409=绑定非 active detail「请先绑定百度网盘账号」;
  /// truncated=true 提示「目录过大,分批浏览」)。
  Future<BaiduNetdiskFolders> netdiskFolders(String path) async {
    final r = await _api.guard5xx(
        _api.http
            .get('/api/v1/baidu/backup/netdisk/folders', queryParameters: {
          'path': path,
        }),
        '读取网盘目录失败');
    if (r.statusCode == 404) throw ApiException(404, '网盘备份未启用');
    if (r.statusCode != 200) throw _api.err(r, '读取网盘目录失败');
    return BaiduNetdiskFolders.fromJson(r.data as Map<String, dynamic>);
  }

  // ── 任务族(B9 §8.10;仅本人)───────────────────────────────────────────

  /// GET /backup/tasks — 本人任务分页(created_at DESC 稳定排序)。
  Future<BaiduTasksPage> listTasks({int limit = 20, int offset = 0}) async {
    final r = await _api.guard5xx(
        _api.http.get('/api/v1/baidu/backup/tasks', queryParameters: {
          'limit': limit,
          'offset': offset,
        }),
        '备份任务加载失败');
    if (r.statusCode == 404) throw ApiException(404, '网盘备份未启用');
    if (r.statusCode != 200) throw _api.err(r, '备份任务加载失败');
    return BaiduTasksPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// GET /backup/tasks/{id} — 任务详情(字段与列表同口径)。
  Future<BaiduTask> getTask(String taskId) async {
    final r = await _api.guard5xx(
        _api.http.get('/api/v1/baidu/backup/tasks/$taskId'), '任务详情加载失败');
    if (r.statusCode != 200) throw _api.err(r, '任务详情加载失败');
    return BaiduTask.fromJson(r.data as Map<String, dynamic>);
  }

  /// GET /backup/tasks/{id}/files — manifest 分页(status 行级筛选,
  /// 取值=pending/importing/success/skipped_exists/failed/cancelled)。
  Future<BaiduTaskFilesPage> taskFiles(
    String taskId, {
    String? status,
    int limit = 20,
    int offset = 0,
  }) async {
    final r = await _api.guard5xx(
        _api.http.get('/api/v1/baidu/backup/tasks/$taskId/files',
            queryParameters: {
              if (status != null && status.isNotEmpty) 'status': status,
              'limit': limit,
              'offset': offset,
            }),
        '文件明细加载失败');
    if (r.statusCode != 200) throw _api.err(r, '文件明细加载失败');
    return BaiduTaskFilesPage.fromJson(r.data as Map<String, dynamic>);
  }

  /// POST /backup/tasks — 创建任务(source_dir/project_id 必选,
  /// target_folder_id 不传 = 项目根自动创建承接夹;同名默认跳过,向导无覆盖
  /// 选项——覆盖导入是任务详情内逐文件后置操作)。201 返回任务。
  Future<BaiduTask> createTask({
    required String sourceDir,
    required String projectId,
    String? targetFolderId,
  }) async {
    final r = await _api.guard5xx(
        _api.http.post('/api/v1/baidu/backup/tasks', data: {
          'source_dir': sourceDir,
          'project_id': projectId,
          'target_folder_id': ?targetFolderId,
        }),
        '创建任务失败');
    if (r.statusCode != 200 && r.statusCode != 201) {
      throw _api.err(r, '创建任务失败');
    }
    return BaiduTask.fromJson(r.data as Map<String, dynamic>);
  }

  /// POST /backup/tasks/{id}/cancel — 取消(202 {finalized} 区分直接终态化/
  /// 交 worker 消费;409=任务已结束)。
  Future<BaiduCancelOut> cancelTask(String taskId) async {
    final r = await _api.guard5xx(
        _api.http.post('/api/v1/baidu/backup/tasks/$taskId/cancel'),
        '取消失败');
    if (r.statusCode != 202 && r.statusCode != 200) {
      throw _api.err(r, '取消失败');
    }
    return BaiduCancelOut.fromJson(r.data as Map<String, dynamic>);
  }

  /// DELETE /backup/tasks/{id} — 删除任务记录(仅终态;409=未结束)。
  Future<void> deleteTask(String taskId) async {
    final r = await _api.guard5xx(
        _api.http.delete('/api/v1/baidu/backup/tasks/$taskId'), '删除失败');
    if (r.statusCode != 204 && r.statusCode != 200) {
      throw _api.err(r, '删除失败');
    }
  }

  /// POST /backup/tasks/{id}/retry-failed — 全部重试失败(仅 failed 任务;
  /// 断点续传语义,202 返回复活状态)。
  Future<BaiduReviveOut> retryFailed(String taskId) async {
    final r = await _api.guard5xx(
        _api.http.post('/api/v1/baidu/backup/tasks/$taskId/retry-failed'),
        '重试失败');
    if (r.statusCode != 202 && r.statusCode != 200) {
      throw _api.err(r, '重试失败');
    }
    return BaiduReviveOut.fromJson(r.data as Map<String, dynamic>);
  }

  // ── 文件级三操作(用户侧端点;B8 AdminBaiduApi 同族,本域供用户页直调)──

  /// POST /backup/tasks/{id}/files/{fid}/retry — 单文件重试(non_retryable
  /// 行后端 409;任务须 failed)。
  Future<BaiduReviveOut> retryFile(String taskId, String fileId) =>
      fileOp(taskId, fileId, 'retry');

  /// POST .../overwrite — 覆盖导入(skipped_exists 或 key_conflict 失败行;
  /// 清除-再导入,需对占用者有管理权限)。
  Future<BaiduReviveOut> overwriteFile(String taskId, String fileId) =>
      fileOp(taskId, fileId, 'overwrite');

  /// POST .../random-suffix — 随机后缀导入(key_conflict 失败行出路)。
  Future<BaiduReviveOut> randomSuffixFile(String taskId, String fileId) =>
      fileOp(taskId, fileId, 'random-suffix');

  Future<BaiduReviveOut> fileOp(
      String taskId, String fileId, String action) async {
    final r = await _api.guard5xx(
        _api.http.post(
            '/api/v1/baidu/backup/tasks/$taskId/files/$fileId/$action'),
        '操作失败');
    if (r.statusCode != 202 && r.statusCode != 200) {
      throw _api.err(r, '操作失败');
    }
    return BaiduReviveOut.fromJson(r.data as Map<String, dynamic>);
  }
}
