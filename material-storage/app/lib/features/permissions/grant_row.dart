/// GrantRow — 临时授权行 + GrantCountdown 同款倒计时(B7 §8.7,web
/// MyPermissionsPage 行 + GrantCountdown 移动版):
/// ACCESS/DOWNLOAD chip + 对象名 + 倒计时(左彩条 emerald/amber/crimson 按
/// 剩余百分比;格式 s / Xm Ys / Xh Ym / Xd Yh 同 web fmt;永久/已过期灰标)。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/badge.dart';

/// 剩余秒 → web GrantCountdown fmt 同款:<60 → Xs;<1h → Xm Ys;<1d → Xh Ym;
/// 其余 → Xd Yh。负数按 floor 取 0 侧(已过期由调用方先判)。
String fmtRemain(num s) {
  if (s < 60) return '${s.floor()}s';
  if (s < 3600) return '${(s / 60).floor()}m ${(s % 60).floor()}s';
  if (s < 86400) {
    return '${(s / 3600).floor()}h ${((s % 3600) / 60).floor()}m';
  }
  return '${(s / 86400).floor()}d ${((s % 86400) / 3600).floor()}h';
}

enum GrantCountdownMode { permanent, expired, running }

/// 倒计时规格纯函数(可单测):永久 / 已过期 / 剩余文案 + 彩条色。
/// expires = decided_at + duration_seconds(web 同算式);[now] 注入便于测试;
/// decided_at 缺失按永久兜底(决策响应必有,防御旧数据)。
GrantCountdownSpec countdownSpec(Approval a, {DateTime? now}) {
  final d = a.durationSeconds;
  final decided = DateTime.tryParse(a.decidedAt ?? '');
  if (d == null || decided == null) {
    return const GrantCountdownSpec(
        mode: GrantCountdownMode.permanent, label: '永久', color: Tk.muted);
  }
  final remain = decided.add(Duration(seconds: d)).difference(now ?? DateTime.now());
  if (remain.inMilliseconds <= 0) {
    return const GrantCountdownSpec(
        mode: GrantCountdownMode.expired, label: '已过期', color: Tk.subtle);
  }
  final pct = remain.inMilliseconds / (d * 1000) * 100;
  return GrantCountdownSpec(
    mode: GrantCountdownMode.running,
    label: fmtRemain(remain.inMilliseconds / 1000),
    color: pct < 10 ? Tk.red : (pct < 30 ? Tk.amber : Tk.green),
  );
}

class GrantCountdownSpec {
  const GrantCountdownSpec(
      {required this.mode, required this.label, required this.color});

  final GrantCountdownMode mode;
  final String label;
  final Color color;

  bool get permanent => mode == GrantCountdownMode.permanent;
  bool get expired => mode == GrantCountdownMode.expired;
  bool get running => mode == GrantCountdownMode.running;
}

/// 倒计时控件:running 每秒重算(web setInterval 1000 同款),其余静态。
class GrantCountdown extends StatefulWidget {
  const GrantCountdown({super.key, required this.approval, this.nowProvider});

  final Approval approval;

  /// 测试注入固定时钟;null = DateTime.now。
  final DateTime Function()? nowProvider;

  @override
  State<GrantCountdown> createState() => _GrantCountdownState();
}

class _GrantCountdownState extends State<GrantCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant GrantCountdown old) {
    super.didUpdateWidget(old);
    if (old.approval.id != widget.approval.id) _syncTicker();
  }

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    // 永久/已过期不计时(web:durationSeconds == null 不 setInterval)
    if (countdownSpec(widget.approval, now: _now()).running) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  DateTime _now() => widget.nowProvider?.call() ?? DateTime.now();

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = countdownSpec(widget.approval, now: _now());
    if (spec.permanent || spec.expired) {
      return Badge(label: spec.label);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 左侧 2~3px 状态彩条(web GrantCountdown 方案 B 同视觉语言)
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: spec.color,
            borderRadius:
                const BorderRadius.horizontal(right: Radius.circular(2)),
          ),
        ),
        const SizedBox(width: 6),
        Text(spec.label, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 4),
        const Text('剩余', style: TextStyle(fontSize: 11, color: Tk.subtle)),
      ],
    );
  }
}

/// 临时授权行:动作 chip(access=访问/download=下载)+ 对象 + 倒计时/
/// 起止时间(web MyPermissionsPage 临时授权区移动版)。
class GrantRow extends StatelessWidget {
  const GrantRow({super.key, required this.approval, this.nowProvider});

  final Approval approval;

  /// 透传给 [GrantCountdown](测试注入固定时钟)。
  final DateTime Function()? nowProvider;

  String get _expiresText {
    final a = approval;
    final decided = DateTime.tryParse(a.decidedAt ?? '')?.toLocal();
    if (decided == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    String f(DateTime t) =>
        '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    if (a.durationSeconds == null) return '${f(decided)} 起 · 永久';
    final expires = decided.add(Duration(seconds: a.durationSeconds!));
    return '${f(decided)} 起 · 到 ${f(expires)}';
  }

  @override
  Widget build(BuildContext context) {
    final a = approval;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Tk.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Badge(
            label: a.action == 'access' ? '访问' : '下载',
            tone: a.action == 'access' ? BadgeTone.accent : BadgeTone.green,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${a.targetTypeLabel} · ${a.targetLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    GrantCountdown(
                        approval: a, nowProvider: nowProvider),
                    if (_expiresText.isNotEmpty) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_expiresText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11, color: Tk.subtle)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
