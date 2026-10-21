/// MyPermissionsPage — 我的权限总览(B7 §8.7;数据源=web MyPermissionsPage
/// 同口径:`GET /projects` 取 my_roles + `GET /approvals?scope=self&status=
/// approved` 已批准临时授权;**勿按逐夹 grants 拼凑**,后端无聚合端点)。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
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
    final results =
        await Future.wait([_settle(api.approvalsOps.list(scope: 'self', status: 'approved')), _settle(api.projects.list())]);
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
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('我的权限')),
        body: ErrorView(message: _error!, onRetry: _reload),
      );
    }
    final grants = _grants ?? const [];
    final owned =
        (_projects ?? const []).where((p) => p.myRoles.isNotEmpty).toList();
    final guest =
        (_projects ?? const []).where((p) => p.myRoles.isEmpty).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('我的权限')),
      body: (_grants == null && _projects == null)
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                if (grants.isNotEmpty) ...[
                  _sectionTitle('临时授权', desc: '审批通过获得的有时效权限,过期失效'),
                  for (final g in grants)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GrantRow(approval: g),
                    ),
                  const SizedBox(height: 12),
                ],
                _sectionTitle('项目角色',
                    desc: '个人、用户组或部门继承而来的角色'),
                if (owned.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: EmptyState(
                        icon: Icons.shield_outlined, message: '你目前没有任何项目角色'),
                  )
                else
                  for (final p in owned)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ProjectRow(project: p),
                    ),
                if (guest.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _sectionTitle('仅访客可见', desc: 'public 项目,能否下载视 folder 设置'),
                  for (final p in guest)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _ProjectRow(project: p, guest: true),
                    ),
                ],
              ],
            ),
    );
  }

  Widget _sectionTitle(String title, {String? desc}) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(desc ?? '',
                  style: const TextStyle(fontSize: 11.5, color: Tk.subtle),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      );
}

/// 项目角色行:名称(code)+ 角色徽标(复用 B2 MyRolesBadge);guest 弱化。
class _ProjectRow extends StatelessWidget {
  const _ProjectRow({required this.project, this.guest = false});

  final Project project;
  final bool guest;

  @override
  Widget build(BuildContext context) {
    final p = project;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(
            color: Tk.border, style: guest ? BorderStyle.none : BorderStyle.solid),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              guest ? p.name : '${p.name}(${p.code})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: guest ? FontWeight.w400 : FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          MyRolesBadge(roles: p.myRoles),
        ],
      ),
    );
  }
}
