/// 登录页(B1 简化 + app-polish E1/E2 + 墨金双主题重做):品牌区真 logo、
/// 用户名 next→密码 done 提交、AutofillGroup + autofillHints、探活闸门
/// (phase!=ready 时登录钮与键盘 done 均不放行)、错误固定高度区、法务外开
/// (短路径→静态页回退→错误区)。本次视觉:loginBg 渐变 + 右上金色光晕 +
/// 桃花层(表单之下、IgnorePointer)+ 品牌区 + 320 宽表单 + 底部法务。
/// 状态/会话/导航/法务逻辑留在本文件,展示件见 login_brand/login_form/
/// login_petals。后端地址由 Session 探活决定,dev/prod/custom 切换已删除。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/context_tk.dart';
import 'login_brand.dart';
import 'login_form.dart';
import 'login_petals.dart';

/// 法务文档(短路径 ↔ 静态页回退路径配对,§决策#10)。
enum _LegalDoc {
  terms('terms', 'terms.html'),
  privacy('privacy', 'privacy.html');

  const _LegalDoc(this.shortPath, this.staticFile);

  /// 公网 nginx 直达短路径:`${baseUrl}/terms`、`${baseUrl}/privacy`
  final String shortPath;

  /// 回退静态页:`${baseUrl}/static/web/terms.html` 等(api 侧托管)
  final String staticFile;
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.openUrl});

  /// H3 外开注入缝(测试用):null → 走 url_launcher
  /// externalApplication(先例 share_create_sheet)。返回是否打开成功。
  final Future<bool> Function(String url)? openUrl;

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

  /// H3:外开法务页(§决策#10)。优先公网 nginx 短路径,失败回退 api 静态
  /// 页;两连失败落固定错误区(不 toast 打扰)。探活未就绪(baseUrl 空)
  /// 直接落错误区——此刻无从拼 URL。
  Future<void> _openLegal(_LegalDoc doc) async {
    final base = session.baseUrl;
    final open = widget.openUrl ?? _launchExternal;
    if (base != null) {
      if (await open('$base/${doc.shortPath}')) return;
      if (await open('$base/static/web/${doc.staticFile}')) return;
    }
    if (!mounted) return;
    setState(() => _error = '打开失败,请稍后重试');
  }

  Future<bool> _launchExternal(String url) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Scaffold(
      backgroundColor: tk.bg,
      body: Stack(
        children: [
          // 背景层:主题渐变 + 右上金色光晕(不拦截触控)。
          Positioned.fill(
            child: Container(
              key: const Key('login_bg'),
              decoration: BoxDecoration(gradient: tk.loginBg),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                key: const Key('login_glow'),
                decoration: BoxDecoration(gradient: tk.loginGlow),
              ),
            ),
          ),
          // 桃花层:在背景之上、表单之下。
          const Positioned.fill(child: IgnorePointer(child: LoginPetals())),
          SafeArea(
            child: AutofillGroup(
              child: LayoutBuilder(
                builder: (context, viewport) {
                  final minHeight =
                      viewport.maxHeight.isFinite && viewport.maxHeight > 58
                      ? viewport.maxHeight - 58
                      : 0.0;
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(26, 34, 26, 24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: minHeight),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Spacer(),
                            const LoginBrand(),
                            const SizedBox(height: 44),
                            Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 320,
                                ),
                                child: LoginForm(
                                  usernameController: _username,
                                  passwordController: _password,
                                  busy: _busy,
                                  error: _error,
                                  phase: session.phase,
                                  onSubmit: _login,
                                  onRetry: session.probe,
                                ),
                              ),
                            ),
                            const Spacer(),
                            Padding(
                              padding: const EdgeInsets.only(top: 24),
                              child: LoginLegalFooter(
                                onOpenTerms: () => _openLegal(_LegalDoc.terms),
                                onOpenPrivacy: () =>
                                    _openLegal(_LegalDoc.privacy),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
