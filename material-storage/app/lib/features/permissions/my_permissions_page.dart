/// MyPermissionsPage — 我的权限总览(§6 F13;数据源=web MyPermissionsPage
/// 同口径:`GET /projects` 取 my_roles + `GET /approvals?scope=self&status=
/// approved` 已批准临时授权;**勿按逐夹 grants 拼凑**,后端无聚合端点)。
/// 页面头/区块标签/SectionCard 行卡;双数据源并行,单源失败不拖垮另一边。
library;

import 'package:flutter/material.dart' hide Badge;

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_row.dart';
import '../../widgets/badge.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/section_label.dart';
import '../../widgets/stat_row.dart';
import '../projects/role_badge.dart';
import 'grant_row.dart';

class MyPermissionsPage extends StatefulWidget {
  const MyPermissionsPage({super.key});

  @override
  State<MyPermissionsPage> createState() => _MyPermissionsPageState();
}

class _MyPermissionsPageState extends State<MyPermissionsPage> {
  List<Approval>? _grants;
  List<Project>? _projects;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// 双数据源并行拉取(一边失败不拖垮另一边:grants 失败仍显项目角色)。
  Future<void> _reload() async {
    setState(() => _error = null);
    final api = session.api!;
    final results = await Future.wait([
      _settle(api.approvalsOps.list(scope: 'self', status: 'approved')),
      _settle(api.projects.list()),
    ]);
    if (!mounted) return;
    setState(() {
      _grants = results[0] as List<Approval>?;
      _projects = results[1] as List<Project>?;
      if (_grants == null && _projects == null) {
        _error = '权限数据加载失败';
      }
    });
  }

  /// 单源失败落 null 不抛(两源独立可用)。
  static Future<T?> _settle<T>(Future<T> f) async {
    try {
      return await f;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const PageHeader(
            back: true,
            title: '我的权限',
            subtitle: '角色决定基础能力，临时授权按有效期失效',
          ),
          Expanded(
            child: _error != null
                ? ErrorView(message: _error!, onRetry: _reload)
                : RefreshIndicator(onRefresh: _reload, child: _buildContent()),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final grants = _grants ?? const <Approval>[];
    final projects = _projects ?? const <Project>[];
    final owned = projects.where((p) => p.myRoles.isNotEmpty).toList();
    final guest = projects.where((p) => p.myRoles.isEmpty).toList();
    final projectNames = {for (final p in projects) p.id: p.name};

    if (_grants == null && _projects == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 200),
          Center(child: CircularProgressIndicator()),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: Tk.spaceMd, bottom: Tk.space2xl),
      children: [
        // P2-5:概览三格,数据全部来自本次已加载数据(不新增请求)。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
          child: StatRow(
            items: [
              StatItem(value: '${owned.length}', label: '项目角色'),
              StatItem(value: '${grants.length}', label: '临时授权'),
              StatItem(value: '${guest.length}', label: '仅访客'),
            ],
          ),
        ),
        // 项目角色(基础能力来源)
        const SectionLabel(title: '项目角色'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
          child: owned.isEmpty
              ? const AppCard(
                  padding: EdgeInsets.symmetric(vertical: Tk.spaceMd),
                  child: EmptyState(
                    icon: Icons.shield_outlined,
                    message: '你目前没有任何项目角色',
                    description: '加入项目后，你的角色会显示在这里。',
                  ),
                )
              : SectionCard(
                  children: [for (final p in owned) _ProjectRow(project: p)],
                ),
        ),
        if (grants.isNotEmpty) ...[
          const SizedBox(height: Tk.spaceMd),
          SectionLabel(title: '临时授权', hint: '${grants.length} 项生效中'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
            child: SectionCard(
              children: [
                for (final g in grants)
                  GrantRow(
                    approval: g,
                    projectName: projectNames[g.parentProjectId],
                  ),
              ],
            ),
          ),
        ],
        if (guest.isNotEmpty) ...[
          const SizedBox(height: Tk.spaceMd),
          const SectionLabel(title: '仅访客', hint: 'public 项目'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Tk.spacePage),
            child: SectionCard(
              children: [
                for (final p in guest) _ProjectRow(project: p, guest: true),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 项目角色行(复用 [AppRow]):名称(code) + 角色徽标(复用 MyRolesBadge)。
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.project, this.guest = false});

  final Project project;
  final bool guest;

  @override
  Widget build(BuildContext context) {
    final p = project;
    return AppRow(
      leading: const Icon(Icons.folder_outlined),
      goldIcon: !guest,
      title: guest ? p.name : '${p.name}(${p.code})',
      trailing: guest
          ? const Badge(label: '仅访客', tone: BadgeTone.neutral)
          : MyRolesBadge(roles: p.myRoles),
      showChevron: false,
    );
  }
}
