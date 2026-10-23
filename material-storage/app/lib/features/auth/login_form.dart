/// 登录表单展示件(§7.2 / F5)——字段、探活状态、金色主按钮、错误固定区、
/// 法务小字行。状态由 LoginPage 持有,本文件只收 props。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/password_field.dart';

// LoginLegalFooter 拆到独立文件(§5.6 行数约束);此处转出,登录页
// 仍只需 `import 'login_form.dart'`。
export 'login_legal_footer.dart';

class LoginForm extends StatelessWidget {
  const LoginForm({
    super.key,
    required this.usernameController,
    required this.passwordController,
    required this.busy,
    required this.error,
    required this.phase,
    required this.onSubmit,
    required this.onRetry,
  });

  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool busy;
  final String? error;
  final SessionPhase phase;
  final VoidCallback onSubmit;
  final VoidCallback onRetry;

  /// 探活就绪才放行:登录钮与键盘 done 同口径(原逻辑不变)。
  bool get _canSubmit => !busy && phase == SessionPhase.ready;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final base = Theme.of(context);
    // 登录输入填充用 loginField;描边用 controlBorder(可交互控件 ≥3:1),
    // loginBorder 为登录页保留令牌(当前输入框不用,以满足对比度);标签始终浮起;
    // PasswordField 不透传 decoration,故在表单级注入 InputDecorationTheme。
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(Tk.rSm),
      borderSide: BorderSide(color: tk.controlBorder),
    );
    return Theme(
      data: base.copyWith(
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          fillColor: tk.loginField,
          floatingLabelBehavior: FloatingLabelBehavior.always,
          border: border,
          enabledBorder: border,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: usernameController,
            style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
            decoration: InputDecoration(
              labelText: '用户名 / 邮箱',
              floatingLabelBehavior: FloatingLabelBehavior.always,
              prefixIcon: Icon(Icons.person_outline, size: 20, color: tk.ink3),
            ),
            autocorrect: false,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
          ),
          const SizedBox(height: Tk.spaceLg),
          PasswordField(
            controller: passwordController,
            labelText: '密码',
            prefixIcon: Icon(Icons.lock_outline, size: 20, color: tk.ink3),
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) {
              if (_canSubmit) onSubmit();
            },
          ),
          // 探活状态(原型位于字段与 CTA 之间):探测中金点脉冲 / 不可达暖色卡。
          if (phase == SessionPhase.probing) ...[
            const SizedBox(height: 14),
            const _ProbeLine(),
          ] else if (phase == SessionPhase.unreachable) ...[
            const SizedBox(height: 14),
            _UnreachableCard(onRetry: onRetry),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _canSubmit ? onSubmit : null,
              child: busy
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                    )
                  : const Text('登录'),
            ),
          ),
          // 固定最小 48 高错误区:空态占位避免布局跳动;P2-1 起允许 1.3
          // 字号两行自然增高(ConstrainedBox 而非定高,不裁切)。
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: Tk.spaceMd),
                child: error == null
                    ? null
                    : Text(
                        error!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tk.danger, fontSize: Tk.fzMd),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「正在连接服务…」金点脉冲(§F5;reduced-motion 时静止)。
class _ProbeLine extends StatelessWidget {
  const _ProbeLine();

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _PulseDot(key: Key('login_probe_pulse')),
        const SizedBox(width: Tk.spaceSm),
        Text(
          '正在连接服务…',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
      ],
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({super.key});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller?.dispose();
      _controller = null;
    } else {
      _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final controller = _controller;
    if (controller == null) return _dot(tk, 0.8);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) =>
          _dot(tk, 0.3 + 0.7 * Curves.easeInOut.transform(controller.value)),
    );
  }

  Widget _dot(TkColors tk, double t) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: tk.gold.withValues(alpha: 0.35 + 0.65 * t),
      boxShadow: [
        BoxShadow(color: tk.gold.withValues(alpha: 0.25 * t), blurRadius: 6),
      ],
    ),
  );
}

/// 探活不可达:暖色卡(surface2 + rMd + warn 图标 + 重试)。
class _UnreachableCard extends StatelessWidget {
  const _UnreachableCard({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      key: const Key('login_unreachable'),
      padding: const EdgeInsets.fromLTRB(
        Tk.spaceMd,
        Tk.spaceSm,
        Tk.spaceXs,
        Tk.spaceSm,
      ),
      decoration: BoxDecoration(
        color: tk.surface2,
        borderRadius: BorderRadius.circular(Tk.rMd),
        border: Border.all(color: tk.line),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_outlined, size: 18, color: tk.warn),
          const SizedBox(width: Tk.spaceSm),
          Expanded(
            child: Text(
              '服务不可达,请检查网络后重试',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
