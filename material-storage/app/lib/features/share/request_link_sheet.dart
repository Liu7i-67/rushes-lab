/// RequestLinkSheet — 请求链接创建(B9 §8.11;2026-10 墨金重做):目标说明卡 +
/// 动作勾选 + 有效期四档 + 限定接收者;创建即复制。403/409/422 detail 透传。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/ms_api.dart';
import '../../core/api/request_links_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/buttons.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/pickers/user_picker_field.dart';
import '../../widgets/sheet_scaffold.dart';

String requestActionLabel(String a) => a == 'access'
    ? '访问(进入敏感目录)'
    : a == 'download'
    ? '下载'
    : a;

Future<void> showRequestLinkSheet(
  BuildContext context, {
  required String targetType, // sensitive_folder / asset / project / folder
  required String targetId,
  required String targetLabel,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _RequestLinkSheet(
    targetType: targetType,
    targetId: targetId,
    targetLabel: targetLabel,
  ),
);

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
  late final bool _canAccess = widget.targetType == 'sensitive_folder';
  late final _actions = _canAccess ? ['access', 'download'] : ['download'];
  var _ttl = 3 * 86400;
  List<UserBrief> _receiver = const [];
  RequestLinkCreated? _result;
  var _submitting = false;
  String? _error;

  void _toggle(String a) => setState(() {
    _actions.contains(a) ? _actions.remove(a) : _actions.add(a);
  });

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
      await Clipboard.setData(ClipboardData(text: r.landingUrl));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message; // 403/409/422 detail 直出
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
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
      setState(() => _error = '打开浏览器失败,请手动打开链接');
    }
  }

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
      child: r == null ? _form(context) : _resultView(context, r),
    );
  }

  Widget _form(BuildContext context) {
    final tk = context.tk;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _targetCard(tk),
        const SizedBox(height: Tk.spaceLg),
        _t('允许接收者申请的动作', Tk.fzMd, tk.ink2, FontWeight.w600),
        if (_canAccess)
          CheckboxListTile(
            value: _actions.contains('access'),
            onChanged: (_) => _toggle('access'),
            contentPadding: EdgeInsets.zero,
            title: Text(requestActionLabel('access')),
            subtitle: const Text('仅对敏感文件夹生效'),
          ),
        CheckboxListTile(
          value: _actions.contains('download'),
          onChanged: (_) => _toggle('download'),
          contentPadding: EdgeInsets.zero,
          title: Text(requestActionLabel('download')),
          subtitle: const Text('审批通过后可下载原文件'),
        ),
        const SizedBox(height: Tk.spaceSm),
        _t('链接有效期', Tk.fzMd, tk.ink2, FontWeight.w600),
        const SizedBox(height: Tk.spaceSm),
        Wrap(
          spacing: Tk.spaceSm,
          runSpacing: Tk.spaceXs,
          children: [
            for (final (label, seconds) in RequestLinksApi.ttlOptions)
              AppChip(
                label: label,
                selected: _ttl == seconds,
                onTap: () => setState(() => _ttl = seconds),
              ),
          ],
        ),
        const SizedBox(height: Tk.spaceLg),
        _t('限定接收者(可选)', Tk.fzMd, tk.ink2, FontWeight.w600),
        const SizedBox(height: Tk.spaceXs),
        _t('留空 = 任意登录用户可用;选了可防转发。', Tk.fzXs, tk.ink3),
        const SizedBox(height: Tk.spaceSm),
        UserPickerField(
          value: _receiver,
          multiple: false,
          hint: '选择用户',
          onChanged: (v) => setState(() => _receiver = v),
        ),
        const SizedBox(height: Tk.spaceLg),
        _t('链接创建后会复制到剪贴板,你可以在浏览器中打开落地页确认。', Tk.fzXs, tk.goldInk),
        const SizedBox(height: Tk.spaceSm),
      ],
    );
  }

  Widget _resultView(BuildContext context, RequestLinkCreated r) {
    final tk = context.tk;
    final expires = DateTime.tryParse(r.expiresAt)?.toLocal();
    final expiresText = expires == null
        ? r.expiresAt
        : '${expires.month.toString().padLeft(2, '0')}-'
              '${expires.day.toString().padLeft(2, '0')} '
              '${expires.hour.toString().padLeft(2, '0')}:'
              '${expires.minute.toString().padLeft(2, '0')}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _t('链接已生成(有效期至 $expiresText),已复制到剪贴板。', Tk.fzMd, tk.ok),
        const SizedBox(height: Tk.spaceMd),
        SelectableText(
          r.landingUrl,
          maxLines: 2,
          style: TextStyle(
            fontSize: Tk.fzMd,
            fontFamily: 'monospace',
            height: 1.4,
            color: tk.ink,
          ),
        ),
        const SizedBox(height: Tk.spaceSm),
        _t(
          '允许动作:${r.allowedActions.map(requestActionLabel).join(' / ')}',
          Tk.fzMd,
          tk.ink3,
        ),
        const SizedBox(height: Tk.spaceMd),
        CopyButton(
          text: r.landingUrl,
          label: '复制链接',
          tooltip: '复制链接',
          onResult: _onCopyResult,
        ),
        const SizedBox(height: Tk.spaceSm),
        OutlinedButton.icon(
          onPressed: _openBrowser,
          icon: const Icon(Icons.open_in_browser_outlined),
          label: const Text('在浏览器打开落地页'),
        ),
      ],
    );
  }

  Widget _targetCard(TkColors tk) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(Tk.spaceMd),
    decoration: BoxDecoration(
      color: tk.surface2,
      border: Border.all(color: tk.line),
      borderRadius: BorderRadius.circular(Tk.rSm),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.link, size: 18, color: tk.goldInk),
        const SizedBox(width: Tk.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.targetLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Tk.fzRowTitle,
                  fontWeight: FontWeight.w600,
                  color: tk.ink,
                ),
              ),
              const SizedBox(height: 2),
              _t(
                '生成后把链接发给接收者;他点开能看到资源信息并发起申请,'
                '不直接获得权限;你照常审批后才生效。',
                Tk.fzXs,
                tk.ink3,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _t(String s, double size, Color c, [FontWeight? w]) => Text(
    s,
    style: TextStyle(fontSize: size, color: c, fontWeight: w),
  );
}
