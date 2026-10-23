/// 分享 bottom sheet(B5;2026-10 墨金重做):目标说明卡 + 有效期四档 AppChip +
/// 访问方式说明;requires_login 恒 true,无提取码/下载开关。结果态=复制链接 +
/// 可选浏览器打开;错误收口 errorText,吸底主按钮金。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/ms_api.dart';
import '../../core/api/share_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/buttons.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/sheet_scaffold.dart';

/// 打开分享面板;[kind]='asset'|'folder'(share.py 双端点同形)。对外 API 不变。
Future<void> showShareSheet(
  BuildContext context, {
  required String kind,
  required String targetId,
  required String targetLabel,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) =>
      _ShareSheet(kind: kind, targetId: targetId, targetLabel: targetLabel),
);

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({
    required this.kind,
    required this.targetId,
    required this.targetLabel,
  });

  final String kind;
  final String targetId;
  final String targetLabel;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  var _ttl = 86400; // web initialValues ttl=86400(24 小时)
  ShareLink? _result;
  var _submitting = false;
  String? _error;

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final r = widget.kind == 'asset'
          ? await session.api!.share.shareAsset(
              widget.targetId,
              expiresInSeconds: _ttl,
            )
          : await session.api!.share.shareFolder(
              widget.targetId,
              expiresInSeconds: _ttl,
            );
      if (!mounted) return;
      setState(() {
        _result = r;
        _submitting = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // D3 错误收口:errorText 位(ApiException detail 透传,余下中文兜底)
        _error = errorMessage(e, '分享失败,请稍后重试');
      });
    }
  }

  /// R1:剪贴板写入由 CopyButton 自理;成功记日志,失败引导长按手动复制。
  void _onCopyResult(bool ok) {
    if (ok) {
      AppLog.info('share', '链接已复制:${widget.targetLabel}');
      return;
    }
    AppLog.error('share', '剪贴板复制失败:${widget.targetLabel}');
    if (!mounted) return;
    setState(() => _error = '复制失败,请长按链接手动复制');
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

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return SheetScaffold(
      title: '创建分享链接',
      errorText: _error,
      bottomActions: r == null
          ? <Widget>[
              PrimaryXl(
                onPressed: _submitting ? null : _submit,
                label: _submitting ? '生成中…' : '生成分享链接',
              ),
            ]
          : <Widget>[
              PrimaryXl(
                onPressed: () => Navigator.of(context).pop(),
                label: '完成',
              ),
            ],
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
        _t('有效期', Tk.fzMd, tk.ink2, FontWeight.w600),
        const SizedBox(height: Tk.spaceSm),
        Wrap(
          spacing: Tk.spaceSm,
          runSpacing: Tk.spaceXs,
          children: [
            for (final (label, seconds) in ShareApi.ttlOptions)
              AppChip(
                label: label,
                selected: _ttl == seconds,
                onTap: () => setState(() => _ttl = seconds),
              ),
          ],
        ),
        const SizedBox(height: Tk.spaceLg),
        _note(
          tk,
          Icons.shield_outlined,
          '访问需登录:收件人打开链接后用本地账号登录即可访问。'
          '分享只读,不包含提取码;下载权限仍按项目角色判定。',
        ),
        const SizedBox(height: Tk.spaceSm),
      ],
    );
  }

  Widget _resultView(BuildContext context, ShareLink r) {
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
        _t('链接已创建,复制后发送给协作者。', Tk.fzMd, tk.ok),
        const SizedBox(height: Tk.spaceMd),
        _t('有效期至 $expiresText', Tk.fzMd, tk.ink3),
        const SizedBox(height: Tk.spaceSm),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Tk.spaceMd),
          decoration: BoxDecoration(
            color: tk.surface2,
            border: Border.all(color: tk.line),
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          // D3:URL 等宽字体+两行截断(长链不撑破弹层;可长按/选择复制)
          child: SelectableText(
            r.landingUrl,
            maxLines: 2,
            style: TextStyle(
              fontSize: Tk.fzMd,
              fontFamily: 'monospace',
              height: 1.4,
              color: tk.ink,
            ),
          ),
        ),
        const SizedBox(height: Tk.spaceMd),
        // R1:复制成功就地 ✓ 反馈(原成功 SnackBar 在 modal 态被本 sheet 遮挡)
        SizedBox(
          width: double.infinity,
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
            label: const Text('在浏览器打开'),
          ),
        ),
        const SizedBox(height: Tk.spaceSm),
        _t('访问需登录:收件人打开链接后用本地账号登录即可访问。', Tk.fzMd, tk.ink3),
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
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: tk.goldSoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.link, size: 18, color: tk.goldInk),
        ),
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
              _t('生成链接后,任何登录成员在有效期内都可以访问。', Tk.fzMd, tk.ink3),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _note(TkColors tk, IconData icon, String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(Tk.spaceMd),
    decoration: BoxDecoration(
      color: tk.goldSoft,
      borderRadius: BorderRadius.circular(Tk.rSm),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: tk.goldInk),
        const SizedBox(width: Tk.spaceSm),
        Expanded(child: _t(text, Tk.fzXs, tk.goldInk)),
      ],
    ),
  );

  Widget _t(String s, double size, Color c, [FontWeight? w]) => Text(
    s,
    style: TextStyle(fontSize: size, color: c, fontWeight: w),
  );
}
