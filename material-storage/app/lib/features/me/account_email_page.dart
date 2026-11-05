/// 账号与安全 · 邮箱页(邮箱账号方案 §7.3):顶部卡片 = 当前邮箱 + 三态
/// Tag(已验证/未验证/未绑定);按状态渲染操作(未绑定=绑定 / 未验证=验证+
/// 更换+解绑 / 已验证=更换+解绑)。绑定/换绑走底部弹层两步流,解绑走密码
/// 弹层+确认对话框(见 account_email_sheets.dart)。三处特殊口径:
/// ① 邮箱功能关闭(emailAuthEnabled==false)但已有邮箱 → 只保留「解除绑定」
///   并提示「邮箱功能暂未开启」(解绑不依赖 SMTP,§5.3.4);
/// ② passwordSet=false → 全部操作禁用并提示「需管理员先初始化密码」;
/// ③ 绑定/换绑/验证/解绑成功后 session.restore() 刷新 Me(邮箱操作不改
///   session_version,不会 401;否则「我的」页/本页仍显示旧状态,§7.3)。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/badge.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'account_email_sheets.dart';

class AccountEmailPage extends StatelessWidget {
  const AccountEmailPage({super.key});

  /// 顶部卡片三态(§7.3):未绑定(中性)/ 未验证(warn)/ 已验证(ok)。
  static (String, BadgeTone) _statusOf(Me me) {
    if (me.email.isEmpty) return ('未绑定', BadgeTone.neutral);
    return me.emailVerified
        ? ('已验证', BadgeTone.ok)
        : ('未验证', BadgeTone.warn);
  }

  Future<void> _openBind(
    BuildContext context, {
    required EmailBindMode mode,
    required Me me,
  }) async {
    final ok = await showEmailBindSheet(
      context,
      mode: mode,
      currentEmail: me.email,
    );
    if (ok && context.mounted) {
      toast(
        context,
        switch (mode) {
          EmailBindMode.bind => '邮箱绑定成功',
          EmailBindMode.change => '邮箱已更换',
          EmailBindMode.verify => '邮箱验证成功',
        },
        tone: ToastTone.success,
      );
      await session.restore(); // 刷新 Me(邮箱/验证态;§7.3)
    }
  }

  Future<void> _openUnbind(BuildContext context) async {
    final ok = await showEmailUnbindSheet(context);
    if (ok && context.mounted) {
      toast(context, '已解除邮箱绑定', tone: ToastTone.success);
      await session.restore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final tk = context.tk;
        final me = session.me;
        final mailReady = session.emailAuthEnabled != false;
        // passwordSet=false(旧后端缺字段同值):后端 /email/* 会 400
        // 「尚未设置本地密码」,不给必然失败的入口(§7.3,与 Web 同口径)
        final opsAllowed = mailReady && (me?.passwordSet ?? false);
        final hasEmail = (me?.email.isNotEmpty ?? false);
        final hint = me == null
            ? null
            : !me.passwordSet
            ? '需管理员先初始化密码。'
            : !mailReady
            ? (hasEmail ? '邮箱功能暂未开启,仅可解除绑定。' : '邮箱功能暂未开启。')
            : null;
        return Scaffold(
          backgroundColor: tk.bg,
          body: Column(
            children: [
              const PageHeader(back: true, title: '邮箱'),
              Expanded(
                child: SafeArea(
                  top: false,
                  child: ListView(
                    padding: const EdgeInsets.all(Tk.spacePage),
                    children: [
                      _StatusCard(me: me),
                      const SizedBox(height: Tk.spaceLg),
                      if (me == null)
                        Text(
                          '会话加载中,请稍候…',
                          style: TextStyle(
                            fontSize: Tk.fzMd,
                            color: tk.ink3,
                          ),
                        )
                      else ...[
                        // 主操作(邮箱功能关闭时不渲染;只有邮箱时仅解绑)
                        if (opsAllowed) ...[
                          if (!hasEmail)
                            _PrimaryAction(
                              key: const Key('email_action_bind'),
                              label: '绑定邮箱',
                              onPressed: () => _openBind(
                                context,
                                mode: EmailBindMode.bind,
                                me: me,
                              ),
                            )
                          else if (!me.emailVerified) ...[
                            _PrimaryAction(
                              key: const Key('email_action_verify'),
                              label: '验证邮箱',
                              onPressed: () => _openBind(
                                context,
                                mode: EmailBindMode.verify,
                                me: me,
                              ),
                            ),
                            const SizedBox(height: Tk.spaceMd),
                            _SecondaryAction(
                              key: const Key('email_action_change'),
                              label: '更换邮箱',
                              onPressed: () => _openBind(
                                context,
                                mode: EmailBindMode.change,
                                me: me,
                              ),
                            ),
                          ] else
                            _PrimaryAction(
                              key: const Key('email_action_change'),
                              label: '更换邮箱',
                              onPressed: () => _openBind(
                                context,
                                mode: EmailBindMode.change,
                                me: me,
                              ),
                            ),
                          const SizedBox(height: Tk.spaceMd),
                        ],
                        // 解绑入口:已有邮箱即显示(不依赖 SMTP/邮箱功能开关;
                        // passwordSet=false 时一并禁用——后端同样要求密码)
                        if (hasEmail)
                          _SecondaryAction(
                            key: const Key('email_action_unbind'),
                            label: '解除绑定',
                            danger: true,
                            onPressed:
                                opsAllowed ? () => _openUnbind(context) : null,
                          ),
                        if (hint != null)
                          Padding(
                            padding: const EdgeInsets.only(top: Tk.spaceMd),
                            child: Text(
                              hint,
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                color: tk.warn,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 顶部状态卡:当前邮箱(未绑定落占位说明)+ 三态 Tag。
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.me});

  final Me? me;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final m = me;
    final (statusLabel, tone) =
        m == null ? ('未知', BadgeTone.neutral) : AccountEmailPage._statusOf(m);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '绑定邮箱',
                  style: TextStyle(
                    fontSize: Tk.fzRowTitle,
                    fontWeight: FontWeight.w500,
                    color: tk.ink,
                  ),
                ),
              ),
              Badge(key: const Key('email_status_badge'), label: statusLabel, tone: tone),
            ],
          ),
          const SizedBox(height: Tk.spaceSm),
          Text(
            m == null
                ? '—'
                : m.email.isEmpty
                ? '尚未绑定邮箱,绑定后可用于找回密码。'
                : m.email,
            style: TextStyle(
              fontSize: Tk.fzBody,
              height: 1.45,
              color: m != null && m.email.isEmpty ? tk.ink3 : tk.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// 主操作钮(金底 48 高,change_password_page 同款)。
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(onPressed: onPressed, child: Text(label)),
    );
  }
}

/// 次操作钮(描边 48 高;danger=true 红字)。
class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: danger ? tk.danger : tk.ink,
          side: BorderSide(
            color: danger ? tk.danger.withValues(alpha: 0.4) : tk.line,
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
