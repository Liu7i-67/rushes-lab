/// GrantRow — 临时授权行 + GrantCountdown(§6 F13):
/// 34 金底钥匙图标 + 目标(类型 · 名称) + 动作/项目/到期时间(13/ink3) +
/// 剩余倒计时(左彩条按剩余百分比 ok/warn/danger;永久/已过期灰标)。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tk_colors.dart';
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
/// [colors] 供 widget 传 `context.tk`;纯函数测试用默认浅色盘。
GrantCountdownSpec countdownSpec(
  Approval a, {
  DateTime? now,
  TkColors colors = TkColors.light,
}) {
  final d = a.durationSeconds;
  final decided = DateTime.tryParse(a.decidedAt ?? '');
  if (d == null || decided == null) {
    return GrantCountdownSpec(
      mode: GrantCountdownMode.permanent,
      label: '永久',
      color: colors.ink2,
    );
  }
  final remain = decided
      .add(Duration(seconds: d))
      .difference(now ?? DateTime.now());
  if (remain.inMilliseconds <= 0) {
    return GrantCountdownSpec(
      mode: GrantCountdownMode.expired,
      label: '已过期',
      color: colors.ink3,
    );
  }
  final pct = remain.inMilliseconds / (d * 1000) * 100;
  return GrantCountdownSpec(
    mode: GrantCountdownMode.running,
    label: fmtRemain(remain.inMilliseconds / 1000),
    color: pct < 10 ? colors.danger : (pct < 30 ? colors.warn : colors.ok),
  );
}

class GrantCountdownSpec {
  const GrantCountdownSpec({
    required this.mode,
    required this.label,
    required this.color,
  });

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
    final tk = context.tk;
    final spec = countdownSpec(widget.approval, now: _now(), colors: tk);
    if (spec.permanent || spec.expired) {
      return Badge(label: spec.label);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 左侧 3px 状态彩条(web GrantCountdown 方案 B 同视觉语言)
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: spec.color,
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(2),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          spec.label,
          style: TextStyle(fontSize: Tk.fzMd, color: tk.ink2),
        ),
        const SizedBox(width: 4),
        Text('剩余', style: TextStyle(fontSize: 11.5, color: tk.ink3)),
      ],
    );
  }
}

/// 临时授权行:目标 + 动作/项目/到期时间(13/ink3) + 倒计时。
class GrantRow extends StatelessWidget {
  const GrantRow({
    super.key,
    required this.approval,
    this.nowProvider,
    this.projectName,
  });

  final Approval approval;

  /// 透传给 [GrantCountdown](测试注入固定时钟)。
  final DateTime Function()? nowProvider;

  /// 由页面用已加载项目列表按 parentProjectId 反查;null 时不显项目段。
  final String? projectName;

  String get _expiresText {
    final a = approval;
    final decided = DateTime.tryParse(a.decidedAt ?? '')?.toLocal();
    if (decided == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    String f(DateTime t) =>
        '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
    if (a.durationSeconds == null) return '永久有效';
    final expires = decided.add(Duration(seconds: a.durationSeconds!));
    return '到期 ${f(expires)}';
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final a = approval;
    final meta = [
      a.actionLabel,
      if ((projectName ?? '').isNotEmpty) projectName!,
      if (_expiresText.isNotEmpty) _expiresText,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Tk.spaceLg,
        vertical: Tk.spaceMd,
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
            child: Icon(Icons.key_outlined, size: 19, color: tk.goldInk),
          ),
          const SizedBox(width: Tk.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${a.targetTypeLabel} · ${a.targetLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Tk.fzMd,
                    height: 1.5,
                    color: tk.ink3,
                  ),
                ),
                const SizedBox(height: Tk.spaceXs),
                GrantCountdown(approval: a, nowProvider: nowProvider),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
