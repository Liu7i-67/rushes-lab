/// 改密页(§2 强制改密流 + app-polish E2 精修):me.must_change_password=true
/// 时全 App 只放行此页(改密/退出可走,无返回);非强制入口(我的页)改完即回。
/// E2:复杂度规则前置 hint(至少 8 位,含字母与数字=后端 local_auth 策略);
/// 成功 toast「密码已更新,请重新登录」反馈后再跳转;错误固定高度区不跳动。
/// 契约:POST /api/v1/auth/change-password {old_password,new_password}(auth.py)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../theme/tokens.dart';
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.forced ? '设置新密码' : '修改密码'),
        automaticallyImplyLeading: !widget.forced,
        actions: [
          if (widget.forced)
            TextButton(onPressed: _busy ? null : _logout, child: const Text('退出登录')),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(Tk.spaceXl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.forced) ...[
              Text(
                '首次登录或密码已被重置,请先设置新密码后继续使用。',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: Tk.spaceLg),
            ],
            // P9:三个密码框均带眼睛切换明文(内容/焦点保持)
            PasswordField(
              controller: _old,
              labelText: '原密码',
              prefixIcon: const Icon(Icons.lock_outline),
            ),
            const SizedBox(height: Tk.spaceMd),
            // E2:复杂度规则前置(后端 local_auth 策略:≥8 位且含字母与数字)
            PasswordField(
              controller: _new,
              labelText: '新密码',
              hintText: '至少 8 位,需包含字母与数字',
              prefixIcon: const Icon(Icons.lock_reset_outlined),
            ),
            const SizedBox(height: Tk.spaceMd),
            PasswordField(
              controller: _confirm,
              labelText: '确认新密码',
              prefixIcon: const Icon(Icons.lock_person_outlined),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: Tk.spaceLg),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('确认修改'),
              ),
            ),
            // E2:错误固定高度区(空态占位,校验/请求失败均落这里不跳动)
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
    );
  }
}
