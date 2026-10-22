/// RequestLinkSheet — 请求链接创建(B9 §8.11,web RequestLinkCreateModal
/// 移动版):动作勾选(access 仅敏感夹)/ 有效期四档(web TTL_PRESETS 实况,
/// 默认 3 天)/ 可选限定接收者(UserPicker 单选);创建即复制落地链接 +
/// 可选系统浏览器打开(web 承载落地页)。**入口闸门在调用侧**(项目页
/// my_roles 含 admin / 项目内 my_can_admin);后端非 admin 403 detail 透传。
/// app-polish D4:「复制链接」改 CopyButton 就地反馈(修 SnackBar 被 sheet
/// 遮挡的 R1 同款回归);表单分组标签统一 fzSm muted+间距节奏;错误收口
/// SheetScaffold errorText 位;骨架迁移 SheetScaffold+PrimaryXl 吸底。
/// app-polish-3 E6:限定接收者改 UserPickerField 弹层形态(单选语义不变,
/// 提交仍取 _receiver.single;分节标题已有说明,字段不带 label,hint「选择用户」)。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/ms_api.dart';
import '../../core/api/request_links_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/pickers/user_picker_field.dart';
import '../../widgets/sheet_scaffold.dart';

/// 动作中文(web ACTION_LABEL)。
String requestActionLabel(String a) =>
    a == 'access' ? '访问(进入敏感目录)' : a == 'download' ? '下载' : a;

/// 对外 API 不变。
Future<void> showRequestLinkSheet(
  BuildContext context, {
  required String targetType, // sensitive_folder / asset / project / folder
  required String targetId,
  required String targetLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _RequestLinkSheet(
        targetType: targetType, targetId: targetId, targetLabel: targetLabel),
  );
}

class _RequestLinkSheet extends StatefulWidget {
  const _RequestLinkSheet({
    required this.targetType,
    required this.targetId,
    required this.targetLabel,
  });

  final String targetType;
  final String targetId;
  final String targetLabel;

  @override
  State<_RequestLinkSheet> createState() => _RequestLinkSheetState();
}

class _RequestLinkSheetState extends State<_RequestLinkSheet> {
  /// access 仅适用 sensitive_folder(web 同款);默认动作随类型
  /// (web defaultActions:canAccess ? [access, download] : [download])。
  late final bool _canAccess = widget.targetType == 'sensitive_folder';
  late final _actions = _canAccess ? ['access', 'download'] : ['download'];
  var _ttl = 3 * 86400;
  List<UserBrief> _receiver = const [];
  RequestLinkCreated? _result;
  var _submitting = false;
  String? _error;

  void _toggleAction(String a) {
    setState(() {
      if (_actions.contains(a)) {
        _actions.remove(a);
      } else {
        _actions.add(a);
      }
    });
  }

  Future<void> _submit() async {
    if (_actions.isEmpty) {
      setState(() => _error = '至少选一个动作');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final r = await session.api!.requestLinks.create(
        targetType: widget.targetType,
        targetId: widget.targetId,
        allowedActions: _actions,
        receiverUserId: _receiver.isEmpty ? null : _receiver.single.id,
        ttlSeconds: _ttl,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _submitting = false;
      });
      // 创建即复制:剪贴板直写;sheet 保持打开提供「浏览器打开落地页」出口,
      // 复制确认由结果视图文案承载(modal 态下 snackbar 不可见)
      await Clipboard.setData(ClipboardData(text: r.landingUrl));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 403(非 admin)/422 detail 透传(e.message 直出,无「ApiException(x):」
        // 英文前缀);5xx 中文兜底已在 API 层收口
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // 断网/超时等传输层异常:中文兜底(§4.1 勿渲染原始异常对象)
        _error = errorMessage(e, '生成失败,请稍后重试');
      });
    }
  }

  Future<void> _openBrowser() async {
    final url = _result?.landingUrl;
    if (url == null) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      // 测试报告 P2-3(R1 遮挡同款):错误走 errorText 位,不再 sheet 内
      // SnackBar(被自身弹层遮挡)
      setState(() => _error = '打开浏览器失败,请手动打开链接');
    }
  }

  /// D4:复制失败降级(通道不可用不静默吞;成功态无 SnackBar——就地 ✓ 反馈)。
  /// P2-3:失败同样不再弹 sheet 内 SnackBar,走 errorText 位。
  void _onCopyResult(bool ok) {
    if (ok) {
      AppLog.info('share', '申请链接已复制:${widget.targetLabel}');
      return;
    }
    AppLog.error('share', '剪贴板复制失败:${widget.targetLabel}');
    if (!mounted) return;
    setState(() => _error = '复制失败,请长按链接手动复制');
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return SheetScaffold(
      title: '生成申请链接',
      errorText: _error,
      bottomActions: r == null
          ? <Widget>[
              PrimaryXl(
                onPressed: _submitting ? null : _submit,
                label: _submitting ? '生成中…' : '生成并复制链接',
              ),
            ]
          : const <Widget>[],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.targetLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: Tk.spaceMd),
          if (r == null) ..._form(context) else ..._resultView(context, r),
        ],
      ),
    );
  }

  /// 分组标签统一口径(D4):fzSm 加粗 + 组前 12/组后 4 间距节奏。
  Widget _groupLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: Tk.spaceMd, bottom: Tk.spaceXs),
        child: Text(text,
            style: const TextStyle(
                fontSize: Tk.fzSm,
                fontWeight: FontWeight.w600,
                color: Tk.muted)),
      );

  List<Widget> _form(BuildContext context) {
    return [
      const Text(
        '生成后把链接发给接收者,他点开后能看到资源信息并发起申请,不直接获得权限;你照常审批后才生效。',
        style: TextStyle(fontSize: Tk.fzSm),
      ),
      _groupLabel('允许接收者申请的动作'),
      if (_canAccess)
        CheckboxListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: EdgeInsets.zero,
          value: _actions.contains('access'),
          onChanged: (_) => _toggleAction('access'),
          title: Text(requestActionLabel('access')),
        ),
      CheckboxListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: EdgeInsets.zero,
        value: _actions.contains('download'),
        onChanged: (_) => _toggleAction('download'),
        title: Text(requestActionLabel('download')),
      ),
      _groupLabel('链接有效期'),
      Wrap(
        spacing: Tk.spaceSm,
        children: [
          for (final (label, seconds) in RequestLinksApi.ttlOptions)
            ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: Tk.fzSm)),
              selected: _ttl == seconds,
              onSelected: (_) => setState(() => _ttl = seconds),
            ),
        ],
      ),
      _groupLabel('限定接收者(可选;留空 = 任意登录用户可用,选了防转发)'),
      UserPickerField(
        value: _receiver,
        multiple: false,
        hint: '选择用户',
        onChanged: (v) => setState(() => _receiver = v),
      ),
    ];
  }

  List<Widget> _resultView(BuildContext context, RequestLinkCreated r) {
    final expires = DateTime.tryParse(r.expiresAt)?.toLocal();
    final expiresText = expires == null
        ? r.expiresAt
        : '${expires.month.toString().padLeft(2, '0')}-'
            '${expires.day.toString().padLeft(2, '0')} '
            '${expires.hour.toString().padLeft(2, '0')}:'
            '${expires.minute.toString().padLeft(2, '0')}';
    return [
      Text('链接已生成(有效期至 $expiresText),已复制到剪贴板。',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: Tk.spaceSm),
      // D4:URL 等宽字体+两行截断(长链不撑破弹层;可长按/选择复制)
      SelectableText(
        r.landingUrl,
        maxLines: 2,
        style: const TextStyle(
            fontSize: Tk.fzMd, fontFamily: 'monospace', height: 1.3),
      ),
      const SizedBox(height: Tk.spaceXs),
      Text('允许动作:${r.allowedActions.map(requestActionLabel).join(' / ')}',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: Tk.spaceMd),
      SizedBox(
        width: double.infinity,
        // D4:复制链接就地 ✓ 反馈(CopyButton;原成功 SnackBar 在 modal 态被
        // 本 sheet 遮挡不可见——R1 同款回归修复)
        child: CopyButton(
          text: r.landingUrl,
          label: '复制链接',
          tooltip: '复制链接',
          onResult: _onCopyResult,
        ),
      ),
      const SizedBox(height: Tk.spaceSm),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _openBrowser,
          icon: const Icon(Icons.open_in_browser_outlined),
          label: const Text('在浏览器打开落地页'),
        ),
      ),
    ];
  }
}
