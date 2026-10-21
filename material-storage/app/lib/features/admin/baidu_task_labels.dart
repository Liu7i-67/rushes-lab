/// 百度备份任务状态文案映射(B8;web labels.ts 同名映射对齐):
/// 任务/文件行状态、cancel_reason、fail_reason → 中文;admin 面展示后端
/// 原始 status/last_error,不做 queued 派生(方案 §3.2)。
library;

import '../../widgets/badge.dart';

/// 任务状态 → 文案(web BAIDU_TASK_STATUS_LABEL,不含派生态 queued)。
const kTaskStatusLabels = <String, String>{
  'enumerating': '清单准备中',
  'running': '进行中',
  'completed': '已完成',
  'cancelled': '已取消',
  'failed': '失败',
};

/// 文件行状态 → 文案(web BAIDU_FILE_STATUS_LABEL)。
const kFileStatusLabels = <String, String>{
  'pending': '等待',
  'importing': '导入中',
  'success': '成功',
  'skipped_exists': '跳过(已存在)',
  'failed': '失败',
  'cancelled': '已取消',
};

/// cancel_reason → 文案(tables.py 取值域;web 页内小表同款)。
const kCancelReasonLabels = <String, String>{
  'user_cancel': '用户取消',
  'binding_replaced': '绑定被更换',
};

/// fail_reason → 文案(web BAIDU_FAIL_REASON_LABEL)。
const kFailReasonLabels = <String, String>{
  'binding_expired': '百度绑定已失效,请重新绑定后重试',
  'timeout': '达到单轮 48h 上限,可用「全部重试失败」断点续传',
  'file_failed': '部分文件失败',
  'enum_rate_limited': '百度接口频控,枚举未完成',
  'enum_failed': '枚举源目录失败',
  'manifest_too_large': '文件数超过 20,000 上限,请拆分目录后重建任务',
  'feature_disabled': '功能已被管理员停用,断点已保留(重新开启后可继续)',
};

String taskStatusText(String s) => kTaskStatusLabels[s] ?? s;

String fileStatusText(String s) => kFileStatusLabels[s] ?? s;

/// 任务状态 → 徽标色(failed 红 / completed 绿 / cancelled 中性 /
/// enumerating 琥珀 / 其余 running=accent)。
BadgeTone baiduTaskTone(String status) => switch (status) {
      'failed' => BadgeTone.red,
      'completed' => BadgeTone.green,
      'cancelled' => BadgeTone.neutral,
      'enumerating' => BadgeTone.amber,
      _ => BadgeTone.accent, // running
    };
