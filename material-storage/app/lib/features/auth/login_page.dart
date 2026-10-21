/// 登录页(B1 简化):只剩 用户名 / 密码 / 登录 + 服务探活状态横幅 +
/// 右上日志推送出口(登录失败兜底)。维护横幅位留 B9 填充。
/// 后端地址由 Session 探活决定(§4),dev/prod/custom 切换与手填地址已删除。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/tokens.dart';
import '../me/log_push.dart';

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
      setState(() => _error = '网络错误:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // 登录都失败时的调试出口:日志推送按钮常驻右上角
            Align(alignment: Alignment.topRight, child: logPushButton(context)),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '浣花视界',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 32),

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
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      onSubmitted: (_) => _busy ? null : _login(),
                      decoration: const InputDecoration(
                        labelText: '密码',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    const SizedBox(height: 20),
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
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _probeBanner(BuildContext context) {
    switch (session.phase) {
      case SessionPhase.probing:
        return const Column(
          children: [
            LinearProgressIndicator(minHeight: 2),
            SizedBox(height: 16),
          ],
        );
      case SessionPhase.unreachable:
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            children: [
              const Icon(Icons.wifi_off_outlined, size: 18, color: Tk.red),
              const SizedBox(width: 8),
              const Expanded(child: Text('服务不可达')),
              TextButton(
                onPressed: session.probe,
                child: const Text('重试'),
              ),
            ],
          ),
        );
      case SessionPhase.ready:
        return const SizedBox.shrink();
    }
  }
}
