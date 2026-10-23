/// BindCodePage — 百度网盘绑定 oob 复制码流程(方案 §8.10 定稿,交互对标
/// web BaiduBindModal):生成授权链接 → 复制/外开系统浏览器 → 浏览器授权 →
/// 复制授权码回填 → POST binding。视图件见 bind_step_views.dart。
///
/// 关键口径:
/// - 授权码一次性使用:提交(无论成败)即清输入态,不自动重试;
/// - 成功 / 失败 / 过期文案分明,失败可重走(重新生成链接或重贴新码);
/// - 脱敏红线(§13):授权链接全文与授权码不写任何 AppLog(拦截器只记
///   host+path 已由 MsApi 保证,本页不新增含 url/code 的日志)。
library;

import 'package:flutter/material.dart' hide Badge;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/baidu_api.dart';
import '../../core/api/ms_api.dart' show ApiException, errorMessage;
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'bind_step_views.dart';

class BindCodePage extends StatefulWidget {
  const BindCodePage({super.key, this.api, this.enabled});

  /// 测试注入;缺省取现役 session 客户端。
  final BaiduApi? api;

  /// 开关显隐注入(缺省读 me.baidu_backup_enabled;关闭时后端 /baidu/* 统一 404)。
  final bool? enabled;

  @override
  State<BindCodePage> createState() => _BindCodePageState();
}

class _BindCodePageState extends State<BindCodePage> {
  BaiduApi get _api => widget.api ?? session.api!.baidu;
  bool get _enabled =>
      widget.enabled ?? session.me?.baiduBackupEnabled ?? false;

  final _codeCtrl = TextEditingController();
  BaiduBindingInfo? _status;
  int _step = 0; // 0=引导生成链接;1=展示链接+回填授权码
  bool _busy = false;
  String? _url;
  String? _msg;
  bool _msgOk = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    if (!_enabled) return;
    try {
      final s = await _api.bindingStatus();
      if (mounted) setState(() => _status = s);
    } catch (_) {
      // 状态行失败不打扰主流程(进入绑定页本身即说明可用)
    }
  }

  void _say(String msg, {required bool ok}) => setState(() {
    _msg = msg;
    _msgOk = ok;
  });

  Future<void> _genUrl() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final url = await _api.authorizeUrl();
      if (mounted) {
        setState(() {
          _url = url;
          _step = 1;
        });
      }
    } on ApiException catch (e) {
      _say(e.status == 404 ? '网盘备份未启用' : e.message, ok: false);
    } catch (e) {
      // 传输层异常中文兜底(§4.1 勿渲染原始异常对象)
      _say(errorMessage(e, '生成授权链接失败,请稍后重试'), ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一次性清空:取码后立即 clear,成败与否都不回填(§8.10 步骤 4)。
  Future<void> _submit() async {
    final code = _codeCtrl.text.trim();
    setState(() {
      _codeCtrl.clear();
      _busy = true;
      _msg = null;
    });
    if (code.isEmpty) {
      _say('请先粘贴授权码', ok: false);
      setState(() => _busy = false);
      return;
    }
    try {
      final b = await _api.bind(code);
      _say('绑定成功:已绑定 ${b.displayName}', ok: true);
      setState(() {
        _status = b;
        _step = 0;
        _url = null;
      });
    } on ApiException catch (e) {
      // 400=无效/过期(后端文案已含 10 分钟口径);404=未启用;429=限频
      _say(
        e.status == 404
            ? '网盘备份未启用'
            : e.status == 400
            ? '${e.message}(请回到上一步重新生成链接)'
            : e.message,
        ok: false,
      );
    } catch (e) {
      // 传输层异常中文兜底(§4.1 勿渲染原始异常对象)
      _say(errorMessage(e, '绑定失败,请稍后重试'), ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyUrl() async {
    if (_url == null) return;
    await Clipboard.setData(ClipboardData(text: _url!));
    if (mounted) {
      // E14:toast 统一(floating 不被弹层遮挡)
      toast(context, '授权链接已复制', tone: ToastTone.success);
    }
  }

  Future<void> _openBrowser() async {
    if (_url == null) return;
    try {
      await launchUrl(Uri.parse(_url!), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        toast(context, '无法打开系统浏览器,请复制链接到浏览器打开', tone: ToastTone.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return Scaffold(
      body: Column(
        children: [
          const PageHeader(
            back: true,
            title: '绑定百度网盘账号',
            subtitle: '通过授权码完成一次绑定',
          ),
          Expanded(
            child: !_enabled
                ? const BindDisabledView()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(
                      Tk.spacePage,
                      Tk.spaceLg,
                      Tk.spacePage,
                      Tk.spaceXl,
                    ),
                    children: [
                      if (_status != null) _statusLine(context),
                      BindStepCard(
                        step: 1,
                        total: 2,
                        title: '获取授权链接',
                        done: _step >= 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '生成百度 OAuth 授权链接,用于确认本人百度账号身份。'
                              '网盘授权仅用于将所选目录只读备份至应用侧,不做修改、'
                              '删除、分享。',
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                height: 1.6,
                                color: tk.ink3,
                              ),
                            ),
                            const SizedBox(height: Tk.spaceMd),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.tonal(
                                onPressed: _busy ? null : _genUrl,
                                child: Text(_step >= 1 ? '重新生成链接' : '生成授权链接'),
                              ),
                            ),
                            if (_step >= 1 && _url != null)
                              BindUrlPanel(
                                url: _url!,
                                onCopy: _copyUrl,
                                onOpen: _openBrowser,
                              ),
                          ],
                        ),
                      ),
                      if (_step >= 1)
                        BindStepCard(
                          step: 2,
                          total: 2,
                          title: '粘贴授权码',
                          done: false,
                          child: BindCodePanel(
                            controller: _codeCtrl,
                            busy: _busy,
                            onSubmit: _submit,
                          ),
                        ),
                      if (_msg != null)
                        Padding(
                          padding: const EdgeInsets.only(top: Tk.spaceMd),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _msgOk
                                    ? Icons.check_circle_outline
                                    : Icons.error_outline,
                                size: 18,
                                color: _msgOk ? tk.ok : tk.danger,
                              ),
                              const SizedBox(width: Tk.spaceSm),
                              Expanded(
                                child: Text(
                                  _msg!,
                                  style: TextStyle(
                                    fontSize: Tk.fzMd,
                                    height: 1.5,
                                    fontWeight: FontWeight.w500,
                                    color: _msgOk ? tk.ok : tk.danger,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _statusLine(BuildContext context) {
    final tk = context.tk;
    final s = _status!;
    final expired = s.status == 'expired';
    final text = s.bound
        ? '当前已绑定:${s.displayName}'
        : '当前未绑定${expired ? '(绑定已失效,请重新授权)' : ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: Tk.spaceMd),
      child: Row(
        children: [
          Badge(
            label: s.bound ? '已绑定' : (expired ? '绑定已过期' : '未绑定'),
            tone: s.bound
                ? BadgeTone.ok
                : (expired ? BadgeTone.warn : BadgeTone.neutral),
          ),
          const SizedBox(width: Tk.spaceSm),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
            ),
          ),
        ],
      ),
    );
  }
}
