/// 分享 bottom sheet(B5 功能点 1「分享」/功能点 4「预览页分享」,对标 web
/// ShareModal):有效期四档=web TTL_OPTIONS 实况(1 小时/24 小时/7 天/30 天,
/// 默认 24 小时);requires_login 恒 true 不做开关;**无提取码/下载开关**
/// (ShareCreateIn 无此字段);创建 → 结果态=landing_url 复制 + 可选系统浏览器
/// 打开 + 「访问需登录」提示(纯链接分享,#154)。
/// R1:复制成功反馈改 CopyButton 就地图标切换(「链接已复制」SnackBar 删除,
/// modal 态下本不可见);失败降级(引导长按手动复制)保留,经 onResult 触发。
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/share_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../services/app_log.dart';
import '../../widgets/copy_button.dart';

/// 打开分享面板;[kind]='asset'|'folder'(share.py 双端点同形)。
Future<void> showShareSheet(
  BuildContext context, {
  required String kind,
  required String targetId,
  required String targetLabel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _ShareSheet(kind: kind, targetId: targetId, targetLabel: targetLabel),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet(
      {required this.kind, required this.targetId, required this.targetLabel});

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

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final r = widget.kind == 'asset'
          ? await session.api!
              .share.shareAsset(widget.targetId, expiresInSeconds: _ttl)
          : await session.api!
              .share.shareFolder(widget.targetId, expiresInSeconds: _ttl);
      if (!mounted) return;
      setState(() {
        _result = r;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('分享失败:$e')));
    }
  }

  /// R1:剪贴板写入由 CopyButton 组件自理;此处仅接结果——成功记业务日志,
  /// 失败保留 web 同款降级语义(通道不可用时不静默吞,引导长按手动复制,
  /// landing_url 已是 SelectableText 可长按全选)。
  void _onCopyResult(bool ok) {
    if (ok) {
      AppLog.info('share', '链接已复制:${widget.targetLabel}');
      return;
    }
    AppLog.error('share', '剪贴板复制失败:${widget.targetLabel}');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('复制失败,请长按链接手动复制')));
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
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('分享${widget.kind == 'asset' ? '文件' : '文件夹'}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(widget.targetLabel,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          if (r == null) ..._form(context) else ..._resultView(context, r),
        ]),
      ),
    );
  }

  List<Widget> _form(BuildContext context) {
    return [
      const Text('有效期'),
      RadioGroup<int>(
        groupValue: _ttl,
        onChanged: (v) => setState(() => _ttl = v ?? _ttl),
        child: Column(
          children: [
            for (final (label, seconds) in ShareApi.ttlOptions)
              RadioListTile<int>(
                value: seconds,
                title: Text(label),
                dense: true,
                visualDensity: VisualDensity.compact,
                contentPadding: EdgeInsets.zero,
              ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? '生成中…' : '生成分享链接'),
        ),
      ),
    ];
  }

  List<Widget> _resultView(BuildContext context, ShareLink r) {
    final expires = DateTime.tryParse(r.expiresAt)?.toLocal();
    final expiresText = expires == null
        ? r.expiresAt
        : '${expires.month.toString().padLeft(2, '0')}-'
            '${expires.day.toString().padLeft(2, '0')} '
            '${expires.hour.toString().padLeft(2, '0')}:'
            '${expires.minute.toString().padLeft(2, '0')}';
    return [
      Text('分享链接(有效期至 $expiresText)',
          style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      SelectableText(r.landingUrl, style: const TextStyle(fontSize: 13)),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        // R1:复制成功就地 ✓ 反馈(原成功 SnackBar 在 modal 态被本 sheet 遮挡)
        child: CopyButton(
          text: r.landingUrl,
          label: '复制链接',
          tooltip: '复制链接',
          onResult: _onCopyResult,
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _openBrowser,
          icon: const Icon(Icons.open_in_browser_outlined),
          label: const Text('在浏览器打开'),
        ),
      ),
      const SizedBox(height: 8),
      Text('访问需登录:收件人打开链接后用本地账号登录即可访问。',
          style: Theme.of(context).textTheme.bodySmall),
    ];
  }
}
