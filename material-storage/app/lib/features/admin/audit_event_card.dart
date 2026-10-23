/// 审计时间线行(B8 功能点 4;web AdminAuditPage EventRow 移动版重做):
/// 左侧金色 2px 竖线 + 标题(事件类型中文映射,14/w500)+ 副标题
/// (操作者 · 时间 · 项目/文件名 · IP,11.5/ink3);展开态=绝对时间/操作者 ID/
/// UA + details 结构化键值(resolved_names 命中 → 名称(id 片段),未命中回落裸值)。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import 'audit_labels.dart';

class AuditEventCard extends StatefulWidget {
  const AuditEventCard({super.key, required this.event});

  final AuditEvent event;

  @override
  State<AuditEventCard> createState() => _AuditEventCardState();
}

class _AuditEventCardState extends State<AuditEventCard> {
  var _expanded = false;

  /// id 片段(短 id;补名 null 时回落展示)。
  String shortId(String id) => id.length > 8 ? '${id.substring(0, 8)}…' : id;

  /// details 值 → 展示串:bool 是/否;ISO 时间串绝对格式;标量原样;
  /// 数组/对象紧凑 JSON(移动端简化,桌面 formatAny 的逐项可读不做)。
  String formatValue(Object? v) {
    if (v is bool) return v ? '是' : '否';
    if (v == null) return '—';
    if (v is String) {
      if (v.length >= 10 && RegExp(r'^\d{4}-\d{2}-\d{2}T').hasMatch(v)) {
        if (DateTime.tryParse(v) != null) return fmtIsoShort(v);
      }
      return v;
    }
    if (v is num) return '$v';
    return jsonEncode(v);
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final e = widget.event;
    final color = auditEventColor(context, e.eventType);
    final projectName =
        e.targetProjectName ??
        (e.targetProjectId != null ? shortId(e.targetProjectId!) : null);
    final assetName =
        e.targetAssetFilename ??
        (e.targetAssetId != null ? shortId(e.targetAssetId!) : null);
    final meta = [projectName, assetName].whereType<String>().join(' · ');
    final sub = [
      e.actorName ?? '系统',
      fmtIsoShort(e.eventTime),
      if (meta.isNotEmpty) meta,
      if (e.requestIp != null) e.requestIp!,
    ].join(' · ');
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 0, 10),
            child: Container(
              key: const Key('audit-timeline-line'),
              width: 2,
              decoration: BoxDecoration(
                color: tk.gold.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(width: Tk.spaceMd),
          Expanded(
            child: InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, Tk.spaceLg, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            auditEventLabel(e.eventType),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.45,
                              fontWeight: FontWeight.w500,
                              color: tk.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: Tk.spaceSm),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 16,
                          color: tk.ink3,
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: tk.ink3),
                    ),
                    if (_expanded) ..._expandedBody(e),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _expandedBody(AuditEvent e) {
    final tk = context.tk;
    final details = e.details;
    final rows = <Widget>[
      Divider(height: 14, color: tk.line),
      _kv('时间', fmtIsoShort(e.eventTime)),
      if (e.actorUserId != null) _kv('操作者 ID', e.actorUserId!),
      if (e.userAgent != null)
        _kv(
          'UA',
          e.userAgent!.length > 120
              ? '${e.userAgent!.substring(0, 120)}…'
              : e.userAgent!,
        ),
      if (e.targetProjectId != null) _kv('项目', e.targetProjectId!),
      if (e.targetAssetId != null) _kv('文件', e.targetAssetId!),
      if (e.targetMinioKey != null) _kv('key', e.targetMinioKey!),
      const SizedBox(height: Tk.spaceXs),
    ];
    if (details.isEmpty) {
      rows.add(
        Text(
          'details: —',
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
        ),
      );
    } else {
      for (final entry in details.entries) {
        final key = entry.key;
        final resolved = e.resolvedNames[key] as String?;
        final value = resolved != null
            ? '$resolved(${shortId('${entry.value}')})'
            : formatValue(entry.value);
        rows.add(_kv(kAuditDetailKeyLabels[key] ?? key, value));
      }
    }
    return rows;
  }

  Widget _kv(String k, String v) {
    final tk = context.tk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$k: ',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
            ),
          ),
        ],
      ),
    );
  }
}
