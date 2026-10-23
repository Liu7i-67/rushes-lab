/// 改密页(§2 强制改密流 + 墨金双主题视觉统一):me.must_change_password=
/// true 时全 App 只放行此页(改密/退出可走,无返回);非强制入口(我的页)
/// 改完即回。校验/提交逻辑与 app-polish E2 保持一致:复杂度 hint、成功
/// toast「密码已更新,请重新登录」后再跳转、错误固定高度区不跳动。
/// 本次只做令牌迁移与视觉统一(PageHeader 二级头 / AppCard surface 卡片 /
/// 金色主按钮 / danger 错误),不改契约:POST /api/v1/auth/change-password
/// {old_password,new_password}(auth.py)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/page_header.dart';
import '../../widgets/password_field.dart';
import '../../widgets/toast.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key, this.forced = false});

  /// true=首登强制流:无返回键,附退出登录出口,成功后进 HomeShell。
  final bool forced;

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final oldPw = _old.text;
    final newPw = _new.text;
    if (oldPw.isEmpty || newPw.isEmpty) {
      setState(() => _error = '请填写原密码与新密码');
      return;
    }
    if (newPw != _confirm.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    if (newPw == oldPw) {
      setState(() => _error = '新密码不能与原密码相同');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.changePassword(oldPw, newPw);
      if (!mounted) return;
      // E2:先出成功反馈(含「重新登录」口径)再跳转——改密后旧会话失效,
      // 强制流进首页由路由守卫接管,非强制流返回上一页
      toast(context, '密码已更新,请重新登录', tone: ToastTone.success);
      if (widget.forced) {
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (r) => false);
      } else {
        Navigator.of(context).pop();
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = errorMessage(e, '网络错误,请稍后重试'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    await session.logout();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Scaffold(
      backgroundColor: tk.bg,
      body: Column(
        children: [
          PageHeader(
            back: !widget.forced,
            title: widget.forced ? '设置新密码' : '修改密码',
            subtitle: '至少 8 位，包含字母与数字',
            actions: [
              if (widget.forced)
                TextButton(
                  onPressed: _busy ? null : _logout,
                  child: const Text('退出登录'),
                ),
            ],
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Tk.spacePage),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (widget.forced) ...[
                            const _ForcedHint(),
                            const SizedBox(height: Tk.spaceLg),
                          ],
                          // P9:三个密码框均带眼睛切换明文(内容/焦点保持)
                          PasswordField(
                            controller: _old,
                            labelText: '原密码',
                            prefixIcon: Icon(
                              Icons.lock_outline,
                              size: 20,
                              color: tk.ink3,
                            ),
                          ),
                          const SizedBox(height: Tk.spaceMd),
                          // E2:复杂度规则前置(后端 local_auth 策略:≥8 位含字母数字)
                          PasswordField(
                            controller: _new,
                            labelText: '新密码',
                            hintText: '至少 8 位,需包含字母与数字',
                            prefixIcon: Icon(
                              Icons.lock_reset_outlined,
                              size: 20,
                              color: tk.ink3,
                            ),
                          ),
                          const SizedBox(height: Tk.spaceMd),
                          PasswordField(
                            controller: _confirm,
                            labelText: '确认新密码',
                            prefixIcon: Icon(
                              Icons.lock_person_outlined,
                              size: 20,
                              color: tk.ink3,
                            ),
                            onSubmitted: (_) {
                              if (!_busy) _submit();
                            },
                          ),
                          const SizedBox(height: Tk.spaceLg),
                          SizedBox(
                            height: 48,
                            child: FilledButton(
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
                                  : const Text('确认修改'),
                            ),
                          ),
                          // E2:错误固定高度区(空态占位,校验/请求失败不跳动)
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
                                          color: tk.danger,
                                          fontSize: Tk.fzMd,
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
            ),
          ),
        ],
      ),
    );
  }
}

/// 强制改密说明条:goldSoft 底 + 金锁图标 + goldInk 文案。
class _ForcedHint extends StatelessWidget {
  const _ForcedHint();

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Container(
      padding: const EdgeInsets.all(Tk.spaceMd),
      decoration: BoxDecoration(
        color: tk.goldSoft,
        borderRadius: BorderRadius.circular(Tk.rSm),
        border: Border.all(color: tk.gold.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_reset_outlined, size: 18, color: tk.goldInk),
          const SizedBox(width: Tk.spaceSm),
          Expanded(
            child: Text(
              '首次登录或密码已被重置,请先设置新密码后继续使用。',
              style: TextStyle(
                fontSize: Tk.fzMd,
                height: 1.5,
                color: tk.goldInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
