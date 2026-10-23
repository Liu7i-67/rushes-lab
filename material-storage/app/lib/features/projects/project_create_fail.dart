/// 创建失败文案归因(自 new_project_sheet.dart 拆出的顶层纯函数,行为零变化;
/// 仅为本体行数收口 ≤300,归因口径注释随函数走)。调用方 new_project_sheet
/// 的 ApiException 分支与对应单测共用;失败态由 SheetScaffold errorText 固定
/// 展示,吸底「创建项目」按钮即重试入口(无需额外失败卡片)。
library;

import '../../core/api/ms_api.dart';

/// B9 起对象型 detail 经 extractDetail 渲染为友好文案(无 message/code 字段
/// 的结构化体只保留 code token),`project_id` 归因判据改读 [ApiException.raw]
/// 原始响应体(文本子串 contains 作为旧口径兜底)。
/// 归因三分口径(P1-1,web NewProjectModal 同源,勿按状态码一刀切):
/// 后端 409 两语义=detail 字符串「项目 code 已存在」(code 冲突)与结构化
/// {code: username_taken[, project_id]}(预检零副作用段 / 竞态 rollback 重抛
/// 带 project_id,残留态=项目已建+艺人未建);500 为艺人段或项目段异常
/// (密码未返回)。纯函数,便于单测。
String projectCreateFailCopy(ApiException e) {
  if (e.status == 409) {
    if (e.message.contains('username_taken')) {
      // 结构化 409(登录名冲突):按 detail.project_id 区分两种残留态
      // (raw=err() 存的整个响应体,兼容直接传 detail 体)
      final raw = e.raw;
      final detail = raw is Map ? (raw['detail'] ?? raw) : null;
      final hasProjectId =
          (detail is Map && detail['project_id'] != null) ||
          e.message.contains('project_id');
      return hasProjectId
          ? '项目已创建,但艺人账号未能建立(登录名刚被占用);可联系管理员在后台'
                '开通账号后在项目成员中添加;或由管理员删除该项目后用新登录名重建'
          : '登录名已被占用;若该艺人此前已开通请勿重复开通(可联系管理员将其加入'
                '本项目成员),否则请更换登录名重试';
    }
    if (e.message.contains('项目 code')) {
      return e.message; // code 冲突:detail 字符串原样即精确文案
    }
    return '创建过程出现异常，请到项目列表确认项目是否已创建';
  }
  if (e.status == 500) {
    // 艺人段/项目段 500:中性引导,不指向性提「密码未生成」(P2-5)
    return '创建过程出现异常，请到项目列表确认项目是否已创建';
  }
  return e.message;
}
