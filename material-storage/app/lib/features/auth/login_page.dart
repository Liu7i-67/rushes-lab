/// 登录页(B1 简化 + app-polish E1 精修 + app-polish-2 H1/H2/H3):品牌区
/// 真 logo(Image.asset 圆角裁剪)/ 用户名 next→密码 done 提交 /
/// AutofillGroup + autofillHints(username/password)/ 错误固定高度区(不
/// 布局跳动)/ 探活失败横幅卡片化(图标+文案+重试,surface2 圆角卡)。
/// H1(#4):探活横幅文案「正在连接服务…」,探活期间输入框保持可用,登录钮
/// 探活中禁用、phase→ready 即恢复;H1 探针实证(P1-1 修复):密码框键盘
/// done 提交与登录钮同口径闸门——探活未就绪(phase!=ready)时提交被忽略
/// (不报错,决策#4),修复前会绕过按钮闸门落「登录失败」错误区;H3(#10):
/// 底部法务小字行,《服务条款》《隐私政策》可点外开(优先 /privacy /terms
/// 短路径,失败回退 /static/web/*.html,再失败落固定错误区)。
/// E1:右上角 logPushButton 开发者入口移除(功能保留在「我的」诊断区)。
/// 后端地址由 Session 探活决定(§4),dev/prod/custom 切换与手填地址已删除。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/tokens.dart';
import '../../widgets/password_field.dart';

/// H3 法务文档(短路径 ↔ 静态页回退路径配对,§决策#10)
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
      return await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
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
                    // E1:密码回车即提交。P1-1(探针实证缺陷修复):提交闸门
                    // 与登录钮同口径——探活未就绪(phase!=ready)时忽略提交,
                    // 防键盘 done 绕过按钮禁用、在 api 未就绪下空指针落
                    // 「登录失败」错误区(决策#4:探活未完成不报错)。
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) =>
                        (_busy || session.phase != SessionPhase.ready)
                            ? null
                            : _login(),
                  ),
                  const SizedBox(height: Tk.spaceLg),
                  // H1(#4):登录钮闸门=探活就绪(phase==ready);探活中禁用,
                  // 就绪即恢复可点(输入框不加任何禁用/遮挡)
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
                  // H3(#10):法务入口小字行(底部收尾)
                  _legalFooter(context),
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
        // H2(#10):真 logo 资源(assets/logo.png,512px 压缩产物),圆角裁剪
        // 替代原语义图标占位;尺寸/排版沿用 E1 品牌区
        ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(Tk.rLg)),
          child: Image.asset(
            'assets/logo.png',
            width: 72,
            height: 72,
            fit: BoxFit.cover,
          ),
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

  /// H3(#10):法务小字行——「登录即代表同意《服务条款》与《隐私政策》」,
  /// 两个书名号文案为可点链接(WidgetSpan+GestureDetector,小字行可换行),
  /// 点击外开系统浏览器(URL 策略见 [_openLegal])。
  Widget _legalFooter(BuildContext context) {
    return Text.rich(
      TextSpan(
        text: '登录即代表同意',
        style: const TextStyle(color: Tk.subtle, fontSize: Tk.fzSm),
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openLegal(_LegalDoc.terms),
              child: const Text(
                '《服务条款》',
                style: TextStyle(color: Tk.accent, fontSize: Tk.fzSm),
              ),
            ),
          ),
          const TextSpan(text: '与'),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openLegal(_LegalDoc.privacy),
              child: const Text(
                '《隐私政策》',
                style: TextStyle(color: Tk.accent, fontSize: Tk.fzSm),
              ),
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  /// 探活横幅:E1 卡片化——surface2 底 rMd 圆角卡(图标+文案+重试钮),
  /// 探测中维持线性细条。H1(#4):补明文案「正在连接服务…」(原「优化网络」
  /// 表述费解),期间输入框保持可用、登录钮闸门见 build。
  Widget _probeBanner(BuildContext context) {
    switch (session.phase) {
      case SessionPhase.probing:
        return const Padding(
          padding: EdgeInsets.only(bottom: Tk.spaceLg),
          child: Column(
            children: [
              LinearProgressIndicator(minHeight: 2),
              SizedBox(height: Tk.spaceSm),
              Text(
                '正在连接服务…',
                style: TextStyle(fontSize: Tk.fzMd, color: Tk.muted),
              ),
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
