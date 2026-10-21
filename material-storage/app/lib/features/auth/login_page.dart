/// 登录页(B1 简化 + app-polish E1 精修):品牌化首屏(accent 圆角容器内
/// 语义图标 +「浣花视界」标题排版)/ 用户名 next→密码 done 提交 /
/// AutofillGroup + autofillHints(username/password)/ 错误固定高度区(不
/// 布局跳动)/ 探活失败横幅卡片化(图标+文案+重试,surface2 圆角卡)。
/// E1:右上角 logPushButton 开发者入口移除(功能保留在「我的」诊断区)。
/// 后端地址由 Session 探活决定(§4),dev/prod/custom 切换与手填地址已删除。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/tokens.dart';
import '../../widgets/password_field.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _restoring = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (session.phase == SessionPhase.ready) _onReady();
    if (mounted) setState(() {});
  }

  /// 探活命中:先试 cookie 会话恢复(重启免登录);强制改密者直达改密页。
  Future<void> _onReady() async {
    if (_restoring || session.me != null || !mounted) return;
    _restoring = true;
    final me = await session.restore();
    _restoring = false;
    if (!mounted || me == null) return;
    _goAfterAuth(me.mustChangePassword);
  }

  void _goAfterAuth(bool mustChange) {
    Navigator.of(context).pushNamedAndRemoveUntil(
      mustChange ? '/change-password' : '/home',
      (r) => false,
      arguments: mustChange,
    );
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final me = await session.login(_username.text.trim(), _password.text);
      if (!mounted) return;
      _goAfterAuth(me.mustChangePassword);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = errorMessage(e, '登录失败,请检查网络后重试'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        // E1:autofill 语义分组(用户名+密码一组,密码管理器整组识别)
        child: AutofillGroup(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Tk.spaceXl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 品牌区:accent 圆角容器内语义图标 + 标题排版 ──
                  _brandHeader(context),
                  const SizedBox(height: Tk.spaceXl),

                  // ── 探活状态横幅(§4):探测中 / 不可达可重试 ──
                  _probeBanner(context),
                  // 维护横幅(B9 §8.12)全局挂 MaterialApp.builder,覆盖
                  // 登录页(见 core/maintenance/maintenance_overlay.dart)

                  TextField(
                    controller: _username,
                    decoration: const InputDecoration(
                      labelText: '用户名 / 邮箱',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    autocorrect: false,
                    // E1:用户名回车跳下一字段
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                  ),
                  const SizedBox(height: Tk.spaceMd),
                  // P9:密码框眼睛切换明文(内容/焦点保持)
                  PasswordField(
                    controller: _password,
                    labelText: '密码',
                    prefixIcon: const Icon(Icons.lock_outline),
                    // E1:密码回车即提交
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _busy ? null : _login(),
                  ),
                  const SizedBox(height: Tk.spaceLg),
                  FilledButton(
                    onPressed:
                        _busy || session.phase != SessionPhase.ready
                            ? null
                            : _login,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Text('登录'),
                    ),
                  ),
                  // E1:错误固定高度预留区(空态也占位,避免布局跳动)
                  SizedBox(
                    height: 48,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: Tk.spaceMd),
                        child: _error == null
                            ? null
                            : Text(
                                _error!,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
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
    );
  }

  Widget _brandHeader(BuildContext context) {
    return Column(
      children: [
        // accent 圆角容器 + 语义图标(不引资源,launcher 图标经容器弱化为点缀)
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: Tk.accent,
            borderRadius: BorderRadius.all(Radius.circular(Tk.rXl)),
          ),
          child: const Icon(Icons.movie_filter_outlined,
              size: 40, color: Tk.surface),
        ),
        const SizedBox(height: Tk.spaceMd),
        Text(
          '浣花视界',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: Tk.spaceXs),
        Text(
          '素材管理协作平台',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Tk.subtle, fontSize: Tk.fzMd),
        ),
      ],
    );
  }

  /// 探活横幅:E1 卡片化——surface2 底 rMd 圆角卡(图标+文案+重试钮),
  /// 探测中维持线性细条。
  Widget _probeBanner(BuildContext context) {
    switch (session.phase) {
      case SessionPhase.probing:
        return const Padding(
          padding: EdgeInsets.only(bottom: Tk.spaceLg),
          child: Column(
            children: [
              LinearProgressIndicator(minHeight: 2),
              SizedBox(height: Tk.spaceLg),
            ],
          ),
        );
      case SessionPhase.unreachable:
        return Padding(
          padding: const EdgeInsets.only(bottom: Tk.spaceLg),
          child: Container(
            padding: const EdgeInsets.fromLTRB(
                Tk.spaceMd, Tk.spaceSm, Tk.spaceXs, Tk.spaceSm),
            decoration: const BoxDecoration(
              color: Tk.surface2,
              borderRadius: BorderRadius.all(Radius.circular(Tk.rMd)),
            ),
            child: Row(
              children: [
                const Icon(Icons.wifi_off_outlined, size: 18, color: Tk.red),
                const SizedBox(width: Tk.spaceSm),
                const Expanded(
                  child: Text(
                    '服务不可达,请检查网络后重试',
                    style: TextStyle(fontSize: Tk.fzMd, color: Tk.muted),
                  ),
                ),
                TextButton(
                  onPressed: session.probe,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      case SessionPhase.ready:
        return const SizedBox.shrink();
    }
  }
}
