/// ForgotPasswordPage — 忘记密码三态页(phone-bind 批,照 login_page 品牌壳
/// +表单区+固定错误区范式):
///   ①手机号 → 获取验证码(CodeSendButton,retry_after 为倒计时初值;400
///     「无法发送验证码」等后端 detail 落固定错误区,原样透出不解释原因);
///   ②验证码 → 重置密码(原子消费;失败 detail 透传;「换个手机号」回①);
///   ③结果视图:账号大字(优先级 username → email → name,仅 name 时附
///     「若显示名重复导致无法登录,请联系管理员」小字)+ 新密码(mono +
///     CopyButton 就地图标反馈——SnackBar 会被遮挡,仓内既有钉子)+ 钉死
///     小字提示 +「去登录」(pushNamedAndRemoveUntil('/'))。
/// retry_after 通道同绑定页:200 响应体直取;非 200 经 ApiException.raw 读
/// (retryAfterOf),无该字段不启动倒计时。
library;

import 'package:flutter/material.dart';

import '../../components/code_send_button.dart';
import '../../core/api/auth_api.dart' show PhoneResetResult, retryAfterOf;
import '../../core/api/ms_api.dart' show ApiException, errorMessage;
import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/form_text_field.dart';
import 'login_petals.dart';

enum _ForgotStep { phone, code, done }

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _sendKey = GlobalKey<CodeSendButtonState>();
  _ForgotStep _step = _ForgotStep.phone;
  bool _sending = false;
  bool _busy = false;
  String? _error;
  PhoneResetResult? _result;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final retry = await session.api!.auth.sendPhoneResetCode(
        _phone.text.trim(),
      );
      if (!mounted) return;
      setState(() => _step = _ForgotStep.code);
      if (retry > 0) _sendKey.currentState?.start(retry);
    } on ApiException catch (e) {
      // 429 冷却/配额与 502 带 retry_after → 启动倒计时;400「无法发送
      // 验证码」等无该字段 → 只落固定错误区(不解释原因)。
      final retry = retryAfterOf(e.raw);
      if (retry > 0) _sendKey.currentState?.start(retry);
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e, '发送失败,请稍后重试'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _confirm() async {
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请输入验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await session.api!.auth.confirmPhoneReset(
        _phone.text.trim(),
        code,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _step = _ForgotStep.done;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e, '重置失败,请稍后重试'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _backToPhone() {
    setState(() {
      _step = _ForgotStep.phone;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Scaffold(
      backgroundColor: tk.bg,
      body: Stack(
        children: [
          // 品牌壳背景层(与登录页同款:渐变 + 金色光晕 + 桃花层,不拦截触控)
          Positioned.fill(
            child: Container(decoration: BoxDecoration(gradient: tk.loginBg)),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(gradient: tk.loginGlow),
              ),
            ),
          ),
          const Positioned.fill(child: IgnorePointer(child: LoginPetals())),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(26, 12, 26, 24),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: switch (_step) {
                          _ForgotStep.phone => _phoneStep(tk),
                          _ForgotStep.code => _codeStep(tk),
                          _ForgotStep.done => _doneStep(tk),
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 态①手机号 ────────────────────────────────────────────────────────────
  Widget _phoneStep(TkColors tk) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '找回密码',
        style: TextStyle(
          fontSize: Tk.fzSection,
          fontWeight: FontWeight.w600,
          color: tk.ink,
        ),
      ),
      const SizedBox(height: Tk.spaceSm),
      Text(
        '输入账号绑定的手机号,验证通过后系统将重置密码',
        style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: tk.ink3),
      ),
      const SizedBox(height: Tk.spaceLg),
      AppTextField(
        controller: _phone,
        label: '手机号',
        keyboardType: TextInputType.phone,
        textInputAction: TextInputAction.done,
      ),
      const SizedBox(height: Tk.spaceLg),
      SizedBox(
        height: 48,
        child: CodeSendButton(
          key: _sendKey,
          onPressed: _sendCode,
          busy: _sending,
        ),
      ),
      _errorArea(tk),
    ],
  );

  // ── 态②验证码 ────────────────────────────────────────────────────────────
  Widget _codeStep(TkColors tk) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '输入验证码',
        style: TextStyle(
          fontSize: Tk.fzSection,
          fontWeight: FontWeight.w600,
          color: tk.ink,
        ),
      ),
      const SizedBox(height: Tk.spaceSm),
      Text(
        '验证码已发送至 ${_phone.text.trim()}',
        style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: tk.ink3),
      ),
      const SizedBox(height: Tk.spaceLg),
      AppTextField(
        controller: _code,
        label: '验证码',
        maxLength: 6,
        counterText: '',
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
      ),
      const SizedBox(height: Tk.spaceLg),
      SizedBox(
        height: 48,
        child: FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                )
              : const Text('重置密码'),
        ),
      ),
      Center(
        child: TextButton(onPressed: _backToPhone, child: const Text('换个手机号')),
      ),
      _errorArea(tk),
    ],
  );

  // ── 态③结果 ─────────────────────────────────────────────────────────────
  Widget _doneStep(TkColors tk) {
    final r = _result!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.check_circle_outline, size: 44, color: tk.ok),
        const SizedBox(height: Tk.spaceMd),
        Text(
          '密码已重置',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: Tk.fzSection,
            fontWeight: FontWeight.w600,
            color: tk.ink,
          ),
        ),
        const SizedBox(height: Tk.spaceLg),
        Text(
          '账号',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
        const SizedBox(height: Tk.spaceXs),
        Text(
          r.displayAccount,
          style: TextStyle(
            fontSize: Tk.fzStat,
            fontWeight: FontWeight.w600,
            color: tk.ink,
          ),
        ),
        if (r.onlyName) ...[
          const SizedBox(height: Tk.spaceXs),
          Text(
            '若显示名重复导致无法登录,请联系管理员',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.warn),
          ),
        ],
        const SizedBox(height: Tk.spaceLg),
        Text(
          '新密码',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
        const SizedBox(height: Tk.spaceXs),
        _PasswordCopyRow(password: r.newPassword),
        const SizedBox(height: Tk.spaceLg),
        Text(
          '请使用该密码登录,首次登录后系统会引导你设置新密码',
          style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: tk.ink3),
        ),
        const SizedBox(height: Tk.spaceLg),
        SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: () =>
                Navigator.of(context)
                    .pushNamedAndRemoveUntil('/', (r) => false),
            child: const Text('去登录'),
          ),
        ),
      ],
    );
  }

  /// 固定最小 48 高错误区(登录页同款范式:空态占位,失败不跳动)。
  Widget _errorArea(TkColors tk) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: Tk.spaceMd),
        child: _error == null
            ? null
            : Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: tk.danger,
                  fontSize: Tk.fzMd,
                  height: 1.5,
                ),
              ),
      ),
    ),
  );
}

/// 新密码行:mono 等宽 + CopyButton 就地图标反馈(copy → ✓ 绿 1.5s 回切,
/// SnackBar 会被弹层/页面遮挡——仓内 mobile-ux-polish-2 R1 既有钉子)。
class _PasswordCopyRow extends StatelessWidget {
  const _PasswordCopyRow({required this.password});

  final String password;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tk.surface2,
        borderRadius: BorderRadius.circular(Tk.rSm),
        border: Border.all(color: tk.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              password,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
            ),
          ),
          const SizedBox(width: Tk.spaceSm),
          CopyButton(text: password, tooltip: '复制新密码'),
        ],
      ),
    );
  }
}
