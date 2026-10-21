/// 审计事件卡片(B8 功能点 4;web AdminAuditPage EventRow 移动版):
/// 收起态=类型 chip + 操作者 + 时间 + 「项目名 · 文件名」/ip 元信息;
/// 展开态=绝对时间/操作者 ID/UA + details 结构化键值(resolved_names 命中
/// → 名称(id 片段),未命中回落裸值)。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/fmt.dart';
import '../../models/models.dart';
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
    final e = widget.event;
    final color = auditEventColor(e.eventType);
    final projectName =
        e.targetProjectName ?? (e.targetProjectId != null ? shortId(e.targetProjectId!) : null);
    final assetName =
        e.targetAssetFilename ?? (e.targetAssetId != null ? shortId(e.targetAssetId!) : null);
    final meta = [projectName, assetName].whereType<String>().join(' · ');
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      decoration: BoxDecoration(
        color: Tk.surface,
        border: Border(left: BorderSide(color: color, width: 3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(e.eventType,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: color, fontWeight: FontWeight.w500)),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(e.actorName ?? '系统',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Spacer(),
              Text(fmtIsoShort(e.eventTime),
                  style: const TextStyle(fontSize: 11, color: Tk.subtle)),
            ]),
            if (meta.isNotEmpty || e.requestIp != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [if (meta.isNotEmpty) meta, if (e.requestIp != null) e.requestIp!]
                      .join('  '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Tk.muted),
                ),
              ),
            if (_expanded) ..._expandedBody(e),
          ]),
        ),
      ),
    );
  }

  List<Widget> _expandedBody(AuditEvent e) {
    final details = e.details;
    final rows = <Widget>[
      const Divider(height: 16),
      _kv('时间', fmtIsoShort(e.eventTime)),
      if (e.actorUserId != null) _kv('操作者 ID', e.actorUserId!),
      if (e.userAgent != null)
        _kv('UA', e.userAgent!.length > 120
            ? '${e.userAgent!.substring(0, 120)}…'
            : e.userAgent!),
      if (e.targetProjectId != null) _kv('项目', e.targetProjectId!),
      if (e.targetAssetId != null) _kv('文件', e.targetAssetId!),
      if (e.targetMinioKey != null) _kv('key', e.targetMinioKey!),
      const SizedBox(height: 4),
    ];
    if (details.isEmpty) {
      rows.add(const Text('details: —',
          style: TextStyle(fontSize: 11, color: Tk.muted)));
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

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$k: ',
                style: const TextStyle(fontSize: 11, color: Tk.subtle)),
            Expanded(
              child: SelectableText(v,
                  style: const TextStyle(fontSize: 11, color: Tk.muted)),
            ),
          ],
        ),
      );
}
