/// BaiduApi — /api/v1/baidu/backup 族薄封装(契约对齐
/// api/app/routers/baidu_backup.py:B0① 只消费 binding 三端点)。
/// 三端点统一经 MsApi.guard5xx 包装:5xx(validateStatus 只放行 <500)在
/// dio 层抛的 badResponse 转 ApiException,后端中文 detail 透传(§4.1,
/// 503=凭证未配置、502=uinfo 失败等),页面 generic catch 不再裸渲染异常对象。
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
}
