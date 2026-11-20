/// AccountPhonePage — 我的 → 账号与安全 → 手机号(绑定/换绑,phone-bind 批):
/// 顶部当前绑定展示(完整号 D13;未绑定提示)+ 换绑/绑定表单(手机号 +
/// 验证码 + 发送倒计时按钮)+ 提交。
///
/// 口径(§7.3):
/// - App 端不做前端格式预校验:依赖后端 400 文案,两端均以服务端 D5 归一化
///   为准(提交前仅 trim,不算校验);
/// - 发送:200 响应体 retry_after 为倒计时初值;非 200 抛 ApiException,
///   retry_after 经 raw['retry_after'] 读(retryAfterOf,不另造返回通道);
///   无该字段(409 占用 / 码作废 429 / BUSINESS_LIMIT_CONTROL 502)不启动
///   倒计时——409 后端已回滚冷却,按钮立即可再点;
/// - 提交成功:toast + session.refreshMe()(notifyListeners 自动刷新「我的」
///   页 subtitle)+ pop;
/// - 409/429/502 detail 透传固定错误区(ApiException message,其余中文兜底)。
library;

import 'package:flutter/material.dart';

import '../../components/code_send_button.dart';
import '../../core/api/auth_api.dart' show retryAfterOf;
import '../../core/api/ms_api.dart' show ApiException, errorMessage;
import '../../core/session.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/form_text_field.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';

class AccountPhonePage extends StatefulWidget {
  const AccountPhonePage({super.key});

  @override
  State<AccountPhonePage> createState() => _AccountPhonePageState();
}

class _AccountPhonePageState extends State<AccountPhonePage> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _sendKey = GlobalKey<CodeSendButtonState>();
  bool _sending = false; // 发送验证码在途
  bool _busy = false; // 绑定提交在途
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _bound => (session.me?.phone ?? '').isNotEmpty;

  Future<void> _sendCode() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final retry = await session.api!.auth.sendPhoneBindCode(
        _phone.text.trim(),
      );
      if (!mounted) return;
      toast(context, '验证码已发送', tone: ToastTone.success);
      if (retry > 0) _sendKey.currentState?.start(retry);
    } on ApiException catch (e) {
      // retry_after 从既有 ApiException.raw 读(钉子);无该字段不 start
      // (409 冷却已回滚 → 按钮立即可再点)。
      final retry = retryAfterOf(e.raw);
      if (retry > 0) _sendKey.currentState?.start(retry);
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e, '发送失败,请稍后重试'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submit() async {
    final phone = _phone.text.trim();
    final code = _code.text.trim();
    if (phone.isEmpty || code.isEmpty) {
      setState(() => _error = '请填写手机号与验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.api!.auth.bindPhone(phone, code);
      if (!mounted) return;
      toast(context, _bound ? '手机号已换绑' : '手机号已绑定', tone: ToastTone.success);
      // 刷新 Me(notifyListeners 同步我的页 subtitle);失败标脏不报错
      await session.refreshMe(reason: '绑定手机号');
      if (!mounted) return;
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e, '绑定失败,请稍后重试'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Scaffold(
      backgroundColor: tk.bg,
      body: Column(
        children: [
          const PageHeader(back: true, title: '手机号', subtitle: '绑定后可用于短信找回密码'),
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
                        _CurrentBindingCard(phone: session.me?.phone),
                        const SizedBox(height: Tk.spaceLg),
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              AppTextField(
                                controller: _phone,
                                label: '手机号',
                                keyboardType: TextInputType.phone,
                                textInputAction: TextInputAction.next,
                              ),
                              const SizedBox(height: Tk.spaceMd),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: AppTextField(
                                      controller: _code,
                                      label: '验证码',
                                      maxLength: 6,
                                      counterText: '',
                                      keyboardType: TextInputType.text,
                                      textInputAction: TextInputAction.done,
                                    ),
                                  ),
                                  const SizedBox(width: Tk.spaceSm),
                                  CodeSendButton(
                                    key: _sendKey,
                                    onPressed: _sendCode,
                                    busy: _sending,
                                  ),
                                ],
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
                                      : Text(_bound ? '确认换绑' : '绑定'),
                                ),
                              ),
                              // 固定最小 48 高错误区(空态占位,失败不跳动;
                              // 409/429/502 后端 detail 原样透出)
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minHeight: 48,
                                ),
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      top: Tk.spaceMd,
                                    ),
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
                              ),
                            ],
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

/// 顶部当前绑定卡:完整号展示(D13);未绑定时灰字提示(不解释、不吓唬)。
class _CurrentBindingCard extends StatelessWidget {
  const _CurrentBindingCard({required this.phone});

  final String? phone;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final bound = (phone ?? '').isNotEmpty;
    return AppCard(
      child: Row(
        children: [
          Icon(Icons.phone_iphone_outlined, size: 20, color: tk.ink3),
          const SizedBox(width: Tk.spaceSm),
          Text(
            '当前绑定',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
          const Spacer(),
          Text(
            bound ? phone! : '未绑定',
            style: TextStyle(
              fontSize: Tk.fzRowTitle,
              fontWeight: FontWeight.w600,
              color: bound ? tk.ink : tk.ink3,
            ),
          ),
        ],
      ),
    );
  }
}
