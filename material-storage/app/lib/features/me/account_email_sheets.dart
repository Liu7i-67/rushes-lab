/// 邮箱页弹层(邮箱账号方案 §7.3,从 account_email_page.dart 拆出):
/// 绑定/换绑/验证 共用底部弹层两步流(新邮箱+当前密码 → 发码 → 6 位码 →
/// 确认,60s 重发倒计时;429 优先用 ApiException.retryAfterSeconds 定倒计时,
/// §5.7.4),解绑 = 密码弹层 + danger 确认对话框。成功 pop(true),由页面
/// 统一 session.restore() 刷新 Me(邮箱操作不改 session_version,安全)。
/// 表单风格照 change_password_page.dart;发码类失败(502/503)页面内提示。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/password_field.dart';
import '../../widgets/sheet_scaffold.dart';

/// 弹层模式:bind=绑定(目标=新邮箱)/ change=换绑 / verify=验证当前邮箱
/// (目标=当前邮箱,无邮箱输入框;后端 purpose 三态同款口径,§5.3.1)。
enum EmailBindMode { bind, change, verify }

/// 与后端宽松校验同口径的轻量格式预检(严格校验在后端 Pydantic,422)。
final RegExp kEmailLightPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// 绑定/换绑/验证弹层;返回是否成功(确认通过)。
Future<bool> showEmailBindSheet(
  BuildContext context, {
  required EmailBindMode mode,
  required String currentEmail,
}) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SheetScaffold(
      title: switch (mode) {
        EmailBindMode.bind => '绑定邮箱',
        EmailBindMode.change => '更换邮箱',
        EmailBindMode.verify => '验证邮箱',
      },
      maxHeightFactor: 0.9,
      child: _EmailBindSheet(mode: mode, currentEmail: currentEmail),
    ),
  );
  return ok ?? false;
}

/// 解绑弹层(密码 + danger 确认对话框,§7.3);返回是否成功解绑。
Future<bool> showEmailUnbindSheet(BuildContext context) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const SheetScaffold(
      title: '解除绑定',
      child: _EmailUnbindSheet(),
    ),
  );
  return ok ?? false;
}

class _EmailBindSheet extends StatefulWidget {
  const _EmailBindSheet({required this.mode, required this.currentEmail});

  final EmailBindMode mode;
  final String currentEmail;

  @override
  State<_EmailBindSheet> createState() => _EmailBindSheetState();
}

class _EmailBindSheetState extends State<_EmailBindSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  /// 第二步态:非 null = 验证码已发送(展示脱敏目标邮箱)。
  String? _sentMasked;
  int _countdown = 0;
  Timer? _timer;

  bool get _isVerify => widget.mode == EmailBindMode.verify;

  @override
  void dispose() {
    _timer?.cancel(); // 弹层随路由销毁即停表,不留 pending timer
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  /// 60s 重发倒计时(发送成功);429 带 Retry-After 时以服务端剩余秒数起表
  /// (§5.7.4)。Timer.periodic 可取消:dispose/归零双路径都不泄漏。
  void _startCountdown(int seconds) {
    _timer?.cancel();
    if (seconds <= 0) return;
    _countdown = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _timer?.cancel();
        return;
      }
      setState(() => _countdown -= 1);
      if (_countdown <= 0) _timer?.cancel();
    });
  }

  String? _validateStep1() {
    if (!_isVerify) {
      final email = _email.text.trim();
      if (email.isEmpty || !kEmailLightPattern.hasMatch(email)) {
        return '请输入有效的新邮箱地址';
      }
    }
    if (_password.text.isEmpty) return '请输入当前密码';
    return null;
  }

  Future<void> _sendCode() async {
    final err = _validateStep1();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // verify 模式目标 = 当前邮箱(§5.3.2 步骤 6:purpose=verify)
      final target = _isVerify ? widget.currentEmail : _email.text.trim();
      final r = await session.api!.auth.sendEmailCode(
        email: target,
        password: _password.text,
      );
      if (!mounted) return;
      setState(() {
        _sentMasked = r.maskedEmail;
        _code.clear();
      });
      _startCountdown(60);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.retryAfterSeconds != null && e.retryAfterSeconds! > 0
            ? '${e.message}(${e.retryAfterSeconds} 秒后可重试)'
            : e.message;
        // 429 带 Retry-After:按服务端剩余秒数定倒计时(§5.7.4),文案解析兜底不需要
        if (e.status == 429 && (e.retryAfterSeconds ?? 0) > 0) {
          _startCountdown(e.retryAfterSeconds!);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorMessage(e, '网络错误,请稍后重试'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _error = '请输入 6 位数字验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.api!.auth.confirmEmailCode(code: code);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorMessage(e, '网络错误,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final masked = _sentMasked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 第一步:新邮箱(bind/change)+ 当前密码;第二步追加 6 位码
        if (masked == null) ...[
          if (!_isVerify)
            TextField(
              key: const Key('email_sheet_new_email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              autofillHints: const [AutofillHints.email],
              style: TextStyle(fontSize: Tk.fzBody, color: tk.ink),
              decoration: const InputDecoration(
                labelText: '新邮箱',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(Icons.mail_outline),
              ),
            ),
          if (!_isVerify) const SizedBox(height: Tk.spaceMd),
        ] else ...[
          Row(
            children: [
              Icon(Icons.mark_email_read_outlined, size: 18, color: tk.ok),
              const SizedBox(width: Tk.spaceSm),
              Expanded(
                child: Text(
                  '验证码已发送至 $masked,10 分钟内有效。',
                  style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
                ),
              ),
            ],
          ),
          const SizedBox(height: Tk.spaceMd),
          TextField(
            key: const Key('email_sheet_code'),
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            autocorrect: false,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: TextStyle(
              fontSize: Tk.fzBody,
              letterSpacing: 4,
              color: tk.ink,
            ),
            decoration: const InputDecoration(
              labelText: '邮箱验证码',
              floatingLabelBehavior: FloatingLabelBehavior.always,
              counterText: '',
              prefixIcon: Icon(Icons.password_outlined),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!_busy) _confirm();
            },
          ),
          const SizedBox(height: Tk.spaceMd),
        ],
        if (masked == null)
          PasswordField(
            key: const Key('email_sheet_password'),
            controller: _password,
            labelText: '当前密码',
            prefixIcon: Icon(Icons.lock_outline, size: 20, color: tk.ink3),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) {
              if (!_busy) _sendCode();
            },
          )
        else
          TextButton(
            key: const Key('email_sheet_resend'),
            onPressed: (_busy || _countdown > 0) ? null : _sendCode,
            child: Text(
              _countdown > 0 ? '重新发送($_countdown s)' : '重新发送',
              style: TextStyle(
                fontSize: Tk.fzMd,
                color: _countdown > 0 ? tk.ink3 : tk.goldInk,
              ),
            ),
          ),
        const SizedBox(height: Tk.spaceLg),
        SizedBox(
          height: 48,
          child: FilledButton(
            key: Key(
              masked == null ? 'email_sheet_send' : 'email_sheet_confirm',
            ),
            onPressed: _busy ? null : (masked == null ? _sendCode : _confirm),
            child: _busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : Text(masked == null ? '发送验证码' : '确认'),
          ),
        ),
        // 错误行(弹层内失败提示;502/503 经 noErrorReport 留在页内)
        SizedBox(
          height: 48,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: Tk.spaceMd),
              child: Text(
                _error ?? '',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tk.danger, fontSize: Tk.fzMd),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmailUnbindSheet extends StatefulWidget {
  const _EmailUnbindSheet();

  @override
  State<_EmailUnbindSheet> createState() => _EmailUnbindSheetState();
}

class _EmailUnbindSheetState extends State<_EmailUnbindSheet> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unbind() async {
    if (_password.text.isEmpty) {
      setState(() => _error = '请输入当前密码');
      return;
    }
    // danger 二次确认(§7.3:解除后将无法通过邮箱找回密码)
    final ok = await showAppConfirm(
      context,
      title: '解除邮箱绑定?',
      content: '解除后将无法通过邮箱找回密码。确定解除?',
      confirmLabel: '解除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.api!.auth.unbindEmail(password: _password.text);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = errorMessage(e, '网络错误,请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '解除后该邮箱不再用于登录与找回密码;如需再次使用须重新绑定。',
          style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: tk.ink2),
        ),
        const SizedBox(height: Tk.spaceMd),
        PasswordField(
          key: const Key('email_unbind_password'),
          controller: _password,
          labelText: '当前密码',
          prefixIcon: Icon(Icons.lock_outline, size: 20, color: tk.ink3),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) {
            if (!_busy) _unbind();
          },
        ),
        const SizedBox(height: Tk.spaceLg),
        SizedBox(
          height: 48,
          child: FilledButton(
            key: const Key('email_unbind_submit'),
            style: FilledButton.styleFrom(
              backgroundColor: tk.danger,
              foregroundColor: tk.onDanger,
            ),
            onPressed: _busy ? null : _unbind,
            child: _busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: tk.onDanger,
                    ),
                  )
                : const Text('解除绑定'),
          ),
        ),
        SizedBox(
          height: 48,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: Tk.spaceMd),
              child: Text(
                _error ?? '',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: tk.danger, fontSize: Tk.fzMd),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
