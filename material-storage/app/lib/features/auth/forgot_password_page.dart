/// 忘记密码页(邮箱账号方案 §7.2,公开页):输入绑定邮箱 → 提交
/// POST /auth/password-reset/request → 成功/失败卡片式反馈(复用登录页
/// 暖色错误卡风格 = _ForcedHint 同款 tone 容器)。502(SMTP 失败)/503
/// (功能未开)靠 auth_api 的 noErrorReport 留在页面内失败卡片,不跳全局
/// 报错页。成功文案必含「请在浏览器中打开邮件里的链接;链接 30 分钟内有效」
/// (App 不做深链,邮件链接落 Web SPA,§7.5);「返回登录」回登录页。
/// 429 优先用 ApiException.retryAfterSeconds 呈现剩余秒数(§5.7.4)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/page_header.dart';

/// 与后端宽松校验同口径的轻量格式预检(严格校验在后端 Pydantic,422)。
final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// 提交结果卡内容(成功/失败二态;null=无)。
class _Result {
  const _Result.ok(this.email)
      : isError = false,
        message = null,
        retryAfterSeconds = null;

  const _Result.fail(this.message, [this.retryAfterSeconds])
      : isError = true,
        email = null;

  final String? email;
  final String? message;
  final int? retryAfterSeconds;
  final bool isError;
}

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _email = TextEditingController();
  bool _busy = false;
  _Result? _result;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (email.isEmpty || !_emailPattern.hasMatch(email)) {
      setState(() => _result = const _Result.fail('请输入有效的邮箱地址'));
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      await session.api!.auth.requestPasswordReset(email: email);
      if (!mounted) return;
      setState(() => _result = _Result.ok(email));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _result = _Result.fail(e.message, e.retryAfterSeconds));
    } catch (e) {
      if (!mounted) return;
      // 传输层异常(断网/超时):中文兜底,不透传异常对象
      setState(
        () => _result = _Result.fail(errorMessage(e, '网络错误,请稍后重试')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final result = _result;
    return Scaffold(
      backgroundColor: tk.bg,
      body: Column(
        children: [
          const PageHeader(back: true, title: '忘记密码'),
          Expanded(
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Tk.spacePage),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '输入账号绑定的邮箱,我们将把重置链接发送到该邮箱。',
                                style: TextStyle(
                                  fontSize: Tk.fzMd,
                                  height: 1.5,
                                  color: tk.ink2,
                                ),
                              ),
                              const SizedBox(height: Tk.spaceLg),
                              TextField(
                                key: const Key('forgot_email'),
                                controller: _email,
                                keyboardType: TextInputType.emailAddress,
                                autocorrect: false,
                                autofillHints: const [AutofillHints.email],
                                style: TextStyle(
                                  fontSize: Tk.fzBody,
                                  color: tk.ink,
                                ),
                                decoration: const InputDecoration(
                                  labelText: '邮箱',
                                  floatingLabelBehavior:
                                      FloatingLabelBehavior.always,
                                  prefixIcon: Icon(Icons.mail_outline),
                                ),
                                onSubmitted: (_) {
                                  if (!_busy) _submit();
                                },
                              ),
                              const SizedBox(height: Tk.spaceLg),
                              SizedBox(
                                height: 48,
                                child: FilledButton(
                                  key: const Key('forgot_submit'),
                                  onPressed: _busy ? null : _submit,
                                  child: _busy
                                      ? SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onPrimary,
                                          ),
                                        )
                                      : const Text('发送重置链接'),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 成功/失败卡片(登录页暖色卡同风格;空态不占位,
                        // 卡片出现/消失允许布局变化)
                        if (result != null) ...[
                          const SizedBox(height: Tk.spaceMd),
                          _ResultCard(result: result),
                        ],
                        const SizedBox(height: Tk.spaceMd),
                        Center(
                          child: TextButton(
                            key: const Key('forgot_back_login'),
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: Text(
                              '返回登录',
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                color: tk.ink2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 结果卡(_ForcedHint 同款容器语言,tone 二态):
/// 成功 = okSoft 底 + ok 图标 + 必含「请在浏览器中打开邮件里的链接;
/// 链接 30 分钟内有效」文案;失败 = dangerSoft 底 + danger 图标 + 后端
/// detail(429 附 Retry-After 秒数)。
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});

  final _Result result;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final r = result;
    final (icon, color, text) = r.isError
        ? (
            Icons.error_outline,
            tk.danger,
            () {
              final base = r.message ?? '发送失败,请稍后重试';
              final wait = r.retryAfterSeconds;
              return wait == null || wait <= 0
                  ? base
                  : '$base($wait 秒后可重试)';
            }(),
          )
        : (
            Icons.mark_email_read_outlined,
            tk.ok,
            '重置链接已发送至 ${r.email}。请在浏览器中打开邮件里的链接完成重置;'
                '链接 30 分钟内有效,仅可使用一次;若未收到请同时检查垃圾邮件。',
          );
    return Container(
      key: Key(r.isError ? 'forgot_error' : 'forgot_success'),
      padding: const EdgeInsets.all(Tk.spaceMd),
      decoration: BoxDecoration(
        color: r.isError ? tk.dangerSoft : tk.okSoft,
        borderRadius: BorderRadius.circular(Tk.rSm),
        border: Border.all(
          color: (r.isError ? tk.danger : tk.ok).withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: Tk.spaceSm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: Tk.fzMd,
                height: 1.5,
                color: r.isError ? tk.danger : tk.ink2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
