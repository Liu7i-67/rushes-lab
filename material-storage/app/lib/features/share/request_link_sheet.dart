/// RequestLinkSheet — 请求链接创建(B9 §8.11,web RequestLinkCreateModal
/// 移动版):动作勾选(access 仅敏感夹)/ 有效期四档(web TTL_PRESETS 实况,
/// 默认 3 天)/ 可选限定接收者(UserPicker 单选);创建即复制落地链接 +
/// 可选系统浏览器打开(web 承载落地页)。**入口闸门在调用侧**(项目页
/// my_roles 含 admin / 项目内 my_can_admin);后端非 admin 403 detail 透传。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/ms_api.dart';
import '../../core/api/request_links_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../widgets/pickers/user_picker.dart';

/// 动作中文(web ACTION_LABEL)。
String requestActionLabel(String a) =>
    a == 'access' ? '访问(进入敏感目录)' : a == 'download' ? '下载' : a;

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
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('至少选一个动作')));
      return;
    }
    setState(() => _submitting = true);
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
      setState(() => _submitting = false);
      // 403(非 admin)/422 detail 透传(e.message 直出,无「ApiException(x):」
      // 英文前缀);5xx 中文兜底已在 API 层收口
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      // 断网/超时等传输层异常:中文兜底(§4.1 勿渲染原始异常对象)
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(errorMessage(e, '生成失败,请稍后重试'))));
    }
  }

  Future<void> _openBrowser() async {
    final url = _result?.landingUrl;
    if (url == null) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('打开浏览器失败,请手动打开链接')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('生成申请链接', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(widget.targetLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (r == null) ..._form(context) else ..._resultView(context, r),
          ],
        ),
      ),
    );
  }

  List<Widget> _form(BuildContext context) {
    return [
      const Text(
        '生成后把链接发给接收者,他点开后能看到资源信息并发起申请,不直接获得权限;你照常审批后才生效。',
        style: TextStyle(fontSize: 12.5),
      ),
      const SizedBox(height: 12),
      const Text('允许接收者申请的动作',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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
      const SizedBox(height: 4),
      const Text('链接有效期',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      Wrap(
        spacing: 8,
        children: [
          for (final (label, seconds) in RequestLinksApi.ttlOptions)
            ChoiceChip(
              label: Text(label, style: const TextStyle(fontSize: 12.5)),
              selected: _ttl == seconds,
              onSelected: (_) => setState(() => _ttl = seconds),
            ),
        ],
      ),
      const SizedBox(height: 8),
      const Text('限定接收者(可选;留空 = 任意登录用户可用,选了防转发)',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      UserPicker(
        value: _receiver,
        multiple: false,
        onChanged: (v) => setState(() => _receiver = v),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? '生成中…' : '生成并复制链接'),
        ),
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
      const SizedBox(height: 8),
      SelectableText(r.landingUrl, style: const TextStyle(fontSize: 13)),
      const SizedBox(height: 4),
      Text('允许动作:${r.allowedActions.map(requestActionLabel).join(' / ')}',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: r.landingUrl));
            if (!context.mounted) return;
            ScaffoldMessenger.maybeOf(context)
              ?..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('链接已复制')));
          },
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制链接'),
        ),
      ),
      const SizedBox(height: 8),
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
