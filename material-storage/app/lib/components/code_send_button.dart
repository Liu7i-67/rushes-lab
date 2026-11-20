/// CodeSendButton — 「发送验证码」倒计时按钮(phone-bind 批,绑定/忘记密码
/// 两页共用):Timer.periodic 每秒 setState 递减(GrantCountdown 同款模式,
/// 仅作实现参照)。本组件只管倒计时态,请求与错误文案由页面层编排——
/// 页面拿到响应后经 `GlobalKey<CodeSendButtonState>` 调 [start]/[reset]:
/// - 200 响应体 retry_after 为初值;
/// - 非 200(429 冷却/配额、502)从 ApiException.raw['retry_after'] 读
///   (retryAfterOf);无该字段(409 占用/码作废 429/BUSINESS_LIMIT_CONTROL
///   502)不调 start,按钮立即可再点(钉子:无 retry_after 不启动倒计时)。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/context_tk.dart';
import '../theme/tokens.dart';

class CodeSendButton extends StatefulWidget {
  const CodeSendButton({
    super.key,
    required this.onPressed,
    this.label = '获取验证码',
    this.busy = false,
  });

  /// 页面层发送动作(在途/错误/retry_after 编排都在页面层)。
  final VoidCallback? onPressed;

  /// 空闲态文案(缺省「获取验证码」)。
  final String label;

  /// 请求在途(页面层置位):禁点;与倒计时态互不干扰。
  final bool busy;

  @override
  State<CodeSendButton> createState() => CodeSendButtonState();
}

class CodeSendButtonState extends State<CodeSendButton> {
  Timer? _timer;
  int _left = 0;

  /// 倒计时进行中(按钮禁点,文案「重新获取(Ns)」)。
  bool get counting => _left > 0;

  /// 以秒数为初值启动倒计时;<=0 直接忽略(无 retry_after 不启动倒计时钉子)。
  void start(int seconds) {
    if (seconds <= 0) return;
    _timer?.cancel();
    setState(() => _left = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _left -= 1;
        if (_left <= 0) {
          _left = 0;
          _timer?.cancel();
          _timer = null;
        }
      });
    });
  }

  /// 立即回可点态(换手机号等场景;倒计时运行中调用才需要)。
  void reset() {
    _timer?.cancel();
    _timer = null;
    if (mounted && _left != 0) setState(() => _left = 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final counting = this.counting;
    final disabled = counting || widget.busy;
    return OutlinedButton(
      onPressed: disabled ? null : widget.onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(108, 48),
        side: BorderSide(color: disabled ? tk.line : tk.controlBorder),
      ),
      child: Text(
        counting ? '重新获取(${_left}s)' : widget.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: Tk.fzMd,
          color: counting ? tk.ink3 : tk.goldInk,
        ),
      ),
    );
  }
}
