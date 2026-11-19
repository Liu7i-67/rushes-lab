/// McpTokensPage — MCP 访问令牌页(2026-11-19 settings-mcp-collapse F8,
/// App 包A;对齐 web TokensSection 能力):列表(名称/前缀/创建/最后使用/
/// 过期/状态)、创建入口(名称+有效期档位,弹层见 mcp_token_create_sheet)、
/// 一次性明文展示、吊销(showAppConfirm → DELETE → Toast)、
/// 「显示已吊销/已过期」开关(include_revoked 重拉)、活跃上限 5 到顶禁用
/// 创建并提示、MCP 端点说明段(当前 API base origin + /mcp,整段可复制)。
/// 空态 EmptyState / 加载 ListSkeleton / 下拉刷新 + 错误重试。
///
/// **契约:导出 [McpTokensPage](无参构造),路由注册(`/mcp-tokens`)归并行包。**
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_confirm.dart';
import '../../widgets/badge.dart';
import '../../widgets/copy_button.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/list_skeleton.dart';
import '../../widgets/page_header.dart';
import '../../widgets/toast.dart';
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
  Future<void> _reload() async {
    try {
      final rows = await session.api!.tokens.listTokens(
        includeRevoked: _includeRevoked,
      );
      if (!mounted) return;
      setState(() {
        _data = rows;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorMessage(e, '令牌列表加载失败'));
    }
  }

  Future<void> _toggleHistory(bool v) async {
    if (v == _includeRevoked) return;
    setState(() => _includeRevoked = v);
    await _reload(); // 失败落 _error(有旧数据时保留列表,行内可见)
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
        const _RiskCard(),
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
        _GuideCard(endpoint: _endpoint),
      ],
    );
  }
}

/// D15 强制文案:令牌管理页必须明示账号级全权限 + 内网明文 http 风险。
class _RiskCard extends StatelessWidget {
  const _RiskCard();

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return AppCard(
      padding: const EdgeInsets.all(Tk.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: tk.warn),
              const SizedBox(width: Tk.spaceSm),
              Expanded(
                child: Text(
                  '令牌=账号级全权限凭证,等同你的密码',
                  style: TextStyle(
                    fontSize: Tk.fzRowTitle,
                    fontWeight: FontWeight.w600,
                    color: tk.warn,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Tk.spaceSm),
          Text(
            '内网入口为明文 http,勿配置到不可信机器。持有令牌即可调用本账号'
            '可访问的全部 API(含上传与下载),请勿粘贴到聊天工具、截图或代码'
            '仓库。怀疑泄露时立即吊销,并修改密码(改密会自动吊销该账号全部'
            '令牌)。',
            style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.ink2),
          ),
        ],
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

/// MCP 端点说明段:端点(origin + /mcp)行内复制 + 整段可复制使用说明
/// (占位版;含明文的完整版在创建成功弹层给出)。
class _GuideCard extends StatelessWidget {
  const _GuideCard({required this.endpoint});

  final String endpoint;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final guide = buildMcpGuide(endpoint: endpoint);
    return AppCard(
      padding: const EdgeInsets.all(Tk.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'MCP 端点',
                  style: TextStyle(
                    fontSize: Tk.fzRowTitle,
                    fontWeight: FontWeight.w600,
                    color: tk.ink,
                  ),
                ),
              ),
              CopyButton(text: endpoint, tooltip: '复制端点'),
            ],
          ),
          const SizedBox(height: Tk.spaceSm),
          AppCard(
            radius: Tk.rSm,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: SelectableText(
              endpoint,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
          const SizedBox(height: Tk.spaceMd),
          Text(
            '在支持 MCP(HTTP 传输)的客户端按以下说明接入;身份=令牌所属用户'
            '本人,权限与网页登录一致。含令牌明文的完整配置说明会在创建令牌成功'
            '时给出,可整段复制。',
            style: TextStyle(fontSize: Tk.fzMd, height: 1.6, color: tk.ink2),
          ),
          const SizedBox(height: Tk.spaceMd),
          CopyButton(text: guide, label: '复制使用说明'),
          const SizedBox(height: Tk.spaceSm),
          AppCard(
            radius: Tk.rSm,
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              guide,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
