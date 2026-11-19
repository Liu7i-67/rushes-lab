/// McpTokensPage — MCP 访问令牌页(2026-11-19 settings-mcp-collapse F8,
/// App 包A;对齐 web TokensSection 能力):列表(名称/前缀/创建/最后使用/
/// 过期/状态)、创建入口(名称+有效期档位,弹层见 mcp_token_create_sheet)、
/// 一次性明文展示、吊销(showAppConfirm → DELETE → Toast)、
/// 「显示已吊销/已过期」开关(include_revoked 重拉)、活跃上限 5 到顶禁用
/// 创建并提示、MCP 端点说明段(收拢至 mcp_shared [McpGuideCard])。
/// 空态 EmptyState / 加载 ListSkeleton / 下拉刷新 + 错误重试。
/// P2 批:缓存后刷新失败给列表顶部行内错误条(点击重试,不再静默滞留);
/// _reload 挂请求代际守卫(旧响应后到一律丢弃)。
///
/// **契约:导出 [McpTokensPage](无参构造),路由注册(`/mcp-tokens`)归并行包。**
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/fmt.dart' show fmtIsoLong;
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
import 'mcp_shared.dart';
import 'mcp_token_create_sheet.dart';

class McpTokensPage extends StatefulWidget {
  const McpTokensPage({super.key});

  @override
  State<McpTokensPage> createState() => _McpTokensPageState();
}

class _McpTokensPageState extends State<McpTokensPage> {
  List<PatToken>? _data;
  String? _error;
  var _includeRevoked = false;
  String? _revokingId;

  /// 单调递增请求代际(P2-3):await 后校验代际,旧响应后到一律丢弃
  /// (成功不覆盖新值、失败不误落错误态),只认最新一次查询。
  int _reqGen = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// MCP 端点 = 当前 API base 的 origin + /mcp(nginx 同源挂载;
  /// session.api!.baseUrl 如 `https://bucket.taoxiplan.com`)。
  String get _endpoint {
    final base = session.api?.baseUrl ?? '';
    return '${base.replaceAll(RegExp(r'/+$'), '')}/mcp';
  }

  int get _activeCount => _data?.where((t) => t.isActive).length ?? 0;

  bool get _full => _activeCount >= kMaxActiveTokens;

  /// 拉列表落态(下拉刷新/重试/开关重拉同路);返回真 future 供 RefreshIndicator。
  /// 代际守卫:仅最新一次请求可落态,慢到的旧响应被丢弃。
  Future<void> _reload() async {
    final gen = ++_reqGen;
    try {
      final rows = await session.api!.tokens.listTokens(
        includeRevoked: _includeRevoked,
      );
      if (!mounted || gen != _reqGen) return;
      setState(() {
        _data = rows;
        _error = null;
      });
    } catch (e) {
      if (!mounted || gen != _reqGen) return;
      setState(() => _error = errorMessage(e, '令牌列表加载失败'));
    }
  }

  Future<void> _toggleHistory(bool v) async {
    if (v == _includeRevoked) return;
    setState(() => _includeRevoked = v);
    await _reload(); // 失败落 _error:有旧数据时行内错误条可见,列表保留
  }

  Future<void> _create() async {
    if (_full) return;
    final created = await showMcpTokenCreateSheet(
      context,
      activeCount: _activeCount,
    );
    if (created == null || !mounted) return;
    // 明文唯一一次展示;结果弹层关闭后再刷新列表
    await showMcpTokenCreatedSheet(
      context,
      token: created,
      endpoint: _endpoint,
    );
    if (mounted) await _reload();
  }

  Future<void> _revoke(PatToken t) async {
    final ok = await showAppConfirm(
      context,
      title: '吊销令牌「${t.name}」?',
      content: '吊销后立即失效且不可恢复;正在使用该令牌的 MCP 客户端会立刻'
          '收到 401。',
      confirmLabel: '确认吊销',
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _revokingId = t.id);
    try {
      await session.api!.tokens.revokeToken(id: t.id);
      if (!mounted) return;
      toast(
        context,
        '已吊销令牌「${t.name}」,下次调用立即失效',
        tone: ToastTone.success,
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      toast(context, errorMessage(e, '吊销失败'), tone: ToastTone.error);
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            back: true,
            title: 'MCP 访问令牌',
            // 首载未落态前不显示计数(避免闪 0/5)
            subtitle: data == null
                ? null
                : '活跃 $_activeCount / $kMaxActiveTokens',
            actions: [
              TextButton(
                onPressed: _full ? null : _create,
                child: const Text('创建令牌'),
              ),
            ],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: _buildBody(data),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(List<PatToken>? data) {
    if (_error != null && data == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          ErrorView(message: _error!, onRetry: _reload),
        ],
      );
    }
    if (data == null) {
      // 首载骨架(AlwaysScrollable 保下拉刷新可用)
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: Tk.spaceMd),
          ListSkeleton(rows: 5),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceMd,
        Tk.spacePage,
        Tk.space2xl,
      ),
      children: [
        // 刷新失败但已有缓存数据:行内错误条(P2-2,一条紧凑提示+点击重试,
        // 旧列表不再静默滞留;重试成功后自动消失)
        if (_error != null) _ErrorBar(onRetry: _reload),
        const PatRiskCard(),
        if (_full) ...[
          const SizedBox(height: Tk.spaceMd),
          Text(
            '已达活跃令牌上限($kMaxActiveTokens 个),请先吊销不再使用的令牌。',
            style: TextStyle(
              fontSize: Tk.fzMd,
              height: 1.5,
              color: context.tk.warn,
            ),
          ),
        ],
        const SizedBox(height: Tk.spaceMd),
        SectionCard(
          children: [
            SwitchListTile(
              value: _includeRevoked,
              onChanged: _toggleHistory,
              title: Text(
                '显示已吊销 / 已过期',
                style: TextStyle(
                  fontSize: Tk.fzRowTitle,
                  fontWeight: FontWeight.w500,
                  color: context.tk.ink,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Tk.spaceMd),
        if (data.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Tk.spaceXl),
            child: EmptyState(
              icon: Icons.vpn_key_outlined,
              title: _includeRevoked ? '暂无任何令牌(含历史)' : '暂无活跃令牌',
              message: '创建访问令牌后,可在 MCP 客户端中以本人身份接入素材库,'
                  '权限与登录一致。',
              actionLabel: _full ? null : '创建令牌',
              onAction: _full ? null : _create,
            ),
          )
        else
          SectionCard(
            children: [
              for (final t in data)
                _TokenRow(
                  token: t,
                  revoking: _revokingId == t.id,
                  onRevoke: () => _revoke(t),
                ),
            ],
          ),
        const SizedBox(height: Tk.spaceXl),
        Text(
          'MCP / AI 接入',
          style: TextStyle(
            fontSize: Tk.fzSm,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
            color: context.tk.ink3,
          ),
        ),
        const SizedBox(height: Tk.spaceSm),
        McpGuideCard(endpoint: _endpoint),
      ],
    );
  }
}

/// 刷新失败行内错误条(P2-2):紧凑一条,danger 配色文案「刷新失败,当前为
/// 缓存数据」+「点击重试」,点击整条 = 重试当前查询(复用既有配色,无新依赖)。
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final danger = TextStyle(fontSize: Tk.fzMd, color: tk.danger);
    return Padding(
      padding: const EdgeInsets.only(bottom: Tk.spaceMd),
      child: InkWell(
        onTap: onRetry,
        borderRadius: BorderRadius.circular(Tk.rSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tk.spaceSm, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: tk.danger),
              const SizedBox(width: Tk.spaceSm),
              Expanded(
                child: Text(
                  '刷新失败,当前为缓存数据',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: danger,
                ),
              ),
              const SizedBox(width: Tk.spaceSm),
              Text('点击重试', style: danger.copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个令牌行:名称+状态徽标 / 前缀 / 创建 / 最后使用 / 过期(+吊销时间),
/// 活跃行带吊销操作(非活跃行落「—」)。
class _TokenRow extends StatelessWidget {
  const _TokenRow({
    required this.token,
    required this.revoking,
    required this.onRevoke,
  });

  final PatToken token;
  final bool revoking;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final t = token;
    final active = t.isActive;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Tk.fzRowTitle,
                          fontWeight: FontWeight.w500,
                          color: tk.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: Tk.spaceSm),
                    Badge(
                      label: t.statusLabel,
                      tone: switch (t.status) {
                        PatTokenStatus.active => BadgeTone.ok,
                        PatTokenStatus.revoked => BadgeTone.neutral,
                        PatTokenStatus.expired => BadgeTone.danger,
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '前缀 ${t.tokenPrefix}…(完整明文仅创建时展示一次)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: tk.ink2,
                  ),
                ),
                const SizedBox(height: 2),
                _metaLine(context, '创建:${fmtIsoLong(t.createdAt)}'),
                _metaLine(
                  context,
                  '最后使用:'
                  '${t.lastUsedAt != null ? fmtIsoLong(t.lastUsedAt!) : '从未使用'}',
                ),
                _metaLine(
                  context,
                  t.status == PatTokenStatus.revoked && t.revokedAt != null
                      ? '过期:${fmtIsoLong(t.expiresAt)}'
                          ' · ${fmtIsoLong(t.revokedAt!)} 吊销'
                      : '过期:${fmtIsoLong(t.expiresAt)}',
                ),
              ],
            ),
          ),
          const SizedBox(width: Tk.spaceSm),
          if (active)
            TextButton(
              onPressed: revoking ? null : onRevoke,
              style: TextButton.styleFrom(
                foregroundColor: tk.danger,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(44, 40),
              ),
              child: Text(revoking ? '吊销中…' : '吊销'),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('—', style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3)),
            ),
        ],
      ),
    );
  }

  Widget _metaLine(BuildContext context, String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: Tk.fzMd, height: 1.5, color: context.tk.ink3),
    );
  }
}
