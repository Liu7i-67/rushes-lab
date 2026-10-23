/// ApprovalsPage — 审批中心(§6 F13):PageHeader(待审数副标题) +
/// AppSegmented 待我审批(scope=all&status=pending)/我发起的(scope=self,
/// 全状态);卡片决策(带确认+备注)成功即局部更新 + 失效 approvals;
/// 403/409/422 detail 透传(决策权由后端 enforce_admin_for_target 守门)。
library;

import 'package:flutter/material.dart';

import '../../core/api/ms_api.dart';
import '../../core/refresh_bus.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'approval_card.dart';

enum _Scope { pending, mine }

class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({super.key});

  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> {
  /// 初始段按身份分流(P2-2,web 默认 self 同款):系统 admin 落「待我审批」,
  /// 非 admin 落「我发起的」—— 防 scope=all 对非 admin 引入全组织噪声。
  _Scope _scope = (session.me?.isSystemAdmin ?? false)
      ? _Scope.pending
      : _Scope.mine;

  List<Approval>? _items;
  String? _error;
  bool _loading = false;

  /// 已加载段的条数(分段计数/页头副标题;未加载段为 null 不显计数)。
  int? _pendingCount;
  int? _mineCount;

  /// 加载代际(P2-3):切段/决策刷新后,慢旧段响应落地时对不上最新代际
  /// 即整包丢弃(数据与 error/loading 均不回落),防旧段覆盖新段。
  int _gen = 0;

  /// 决策 in-flight 的审批 id(仅该卡片按钮禁用,防连点)。
  String? _decidingId;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final gen = ++_gen;
    final scope = _scope;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await session.api!.approvalsOps.list(
        scope: scope == _Scope.pending ? 'all' : 'self',
        status: scope == _Scope.pending ? 'pending' : null,
      );
      if (gen != _gen || !mounted) return; // 过期响应丢弃(旧不覆新)
      setState(() {
        _items = r;
        if (scope == _Scope.pending) {
          _pendingCount = r.length;
        } else {
          _mineCount = r.length;
        }
      });
    } catch (e) {
      if (gen != _gen || !mounted) return; // 旧段失败也不污染新段
      setState(() => _error = errorMessage(e, '审批列表加载失败'));
    } finally {
      // 仅最新代际有权清 _loading(被丢弃的全屏在途路不回来清,否则卡转圈)
      if (gen == _gen && mounted) setState(() => _loading = false);
    }
  }

  Future<void> _decide(Approval a, {required bool approve}) async {
    final note = await _confirm(context, approve: approve);
    if (note == null || !mounted) return;
    setState(() => _decidingId = a.id);
    try {
      final ops = session.api!.approvalsOps;
      final updated = approve
          ? await ops.approve(a.id, decisionNote: note.isEmpty ? null : note)
          : await ops.reject(a.id, decisionNote: note.isEmpty ? null : note);
      if (!mounted) return;
      // 决策成功局部更新(按 id 原地改状态/移除),不整列表重拉——
      // 滚动位置天然保持;「待我审批」段移除已决策项,「我发起的」段就地换新
      setState(() {
        final items = _items;
        if (items != null) {
          _items = [
            for (final x in items)
              if (x.id == a.id)
                // 待审段:已决策项不再出现在待办里(mine 段:就地更新状态)
                (_scope == _Scope.pending) ? null : updated
              else
                x,
          ].whereType<Approval>().toList();
        }
        if (_scope == _Scope.pending) _pendingCount = _items?.length ?? 0;
      });
      toast(context, approve ? '已批准' : '已拒绝', tone: ToastTone.success);
      RefreshBus.I.invalidate('approvals'); // MePage 待审 badge 即时同步
    } catch (e) {
      if (!mounted) return;
      // 403(非目标管理者)/409/422:后端 detail 透传
      toast(context, errorMessage(e, '操作失败'), tone: ToastTone.error);
    } finally {
      if (mounted) setState(() => _decidingId = null);
    }
  }

  /// 确认弹窗;返回备注(可空串),取消返回 null。批准/拒绝均带确认(钉子)。
  Future<String?> _confirm(BuildContext context, {required bool approve}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(approve ? '确认通过该申请?' : '确认拒绝该申请?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: approve ? '备注(可选)' : '告知申请人原因(可选)',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(approve ? '批准' : '拒绝'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '审批中心',
            subtitle: '${_pendingCount ?? 0} 条待我审批',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceMd,
              Tk.spacePage,
              Tk.spaceXs,
            ),
            child: AppSegmented<_Scope>(
              // 两段计数(已加载段显示;未加载段不显,避免编造 0)
              segments: [
                Segment(
                  value: _Scope.pending,
                  label: '待我审批',
                  count: _pendingCount,
                ),
                Segment(value: _Scope.mine, label: '我发起的', count: _mineCount),
              ],
              value: _scope,
              onChanged: (s) {
                setState(() => _scope = s);
                _reload();
              },
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: _buildList(items),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<Approval>? items) {
    if (_loading && items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _reload);
    }
    if (items == null || items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          EmptyState(
            icon: Icons.how_to_vote_outlined,
            title: _scope == _Scope.pending ? '暂无待你审批的申请' : '暂无我发起的申请',
            message: _scope == _Scope.pending
                ? '新的权限申请会出现在这里，通过后会通知申请人。'
                : '在素材预览页申请访问后，审批记录会出现在这里。',
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceMd,
        Tk.spacePage,
        Tk.space2xl,
      ),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: Tk.spaceMd),
      itemBuilder: (context, i) {
        final a = items[i];
        return ApprovalCard(
          approval: a,
          decidable: _scope == _Scope.pending && a.status == 'pending',
          busy: _decidingId == a.id,
          onApprove: () => _decide(a, approve: true),
          onReject: () => _decide(a, approve: false),
        );
      },
    );
  }
}
