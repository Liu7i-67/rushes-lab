/// 审计映射邮箱批次回补(方案 §5.9 第 4-6/7 项):7 个新事件进
/// kAuditEventTypes / kAuditEventLabels,details 契约键进 kAuditDetailKeyLabels,
/// 计数注释与实数一致(72 项 = 71 事件 + 『全部』)。App 无 auth_method
/// 筛选维度,不校验该维度(§5.9 钉子:勿照抄 web)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/admin/audit_labels.dart';

void main() {
  const newEvents = <String>[
    'email_verification_requested',
    'email_verified',
    'email_changed',
    'email_unbound',
    'password_reset_requested',
    'password_reset_completed',
    'password_reset_failed',
  ];

  test('7 个新事件进 kAuditEventTypes 全集(计数注释 72 项 = 71 事件 + 全部)', () {
    for (final e in newEvents) {
      expect(kAuditEventTypes.contains(e), isTrue, reason: '$e 缺失');
    }
    expect(kAuditEventTypes.first, '', reason: '首位恒为『全部』');
    expect(kAuditEventTypes.length, 72,
        reason: '头部计数注释口径:71 事件 + 全部 = 72(2026-11-05 邮箱批次 +7)');
  });

  test('7 个新事件均有中文 label(缺 key 回落裸 token 的约定不兜本批)', () {
    for (final e in newEvents) {
      expect(kAuditEventLabels[e], isNotNull, reason: '$e 缺 label');
      expect(kAuditEventLabels[e], isNot(e), reason: '$e 回落裸 token=未回补');
    }
  });

  test('details 契约键回补(ok/脱敏邮箱/purpose/source/verified_by)', () {
    expect(kAuditDetailKeyLabels['ok'], '结果');
    expect(kAuditDetailKeyLabels['email_masked'], '邮箱(脱敏)');
    expect(kAuditDetailKeyLabels['old_masked'], '原邮箱(脱敏)');
    expect(kAuditDetailKeyLabels['new_masked'], '新邮箱(脱敏)');
    expect(kAuditDetailKeyLabels['purpose'], '用途');
    expect(kAuditDetailKeyLabels['source'], '来源');
    expect(kAuditDetailKeyLabels['verified_by'], '验证人');
    // reason/user_id/action/email 既有键仍在(§5.9 复用)
    expect(kAuditDetailKeyLabels['reason'], '原因');
    expect(kAuditDetailKeyLabels['user_id'], '用户');
    expect(kAuditDetailKeyLabels['action'], '动作');
    expect(kAuditDetailKeyLabels['email'], '邮箱');
  });
}
