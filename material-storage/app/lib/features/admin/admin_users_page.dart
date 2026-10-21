/// AdminUsersPage — 用户管理(B8 功能点 2;web AdminUsersPage 移动版):
/// 列表(q/is_active 筛选 + 服务端分页)+ 建号入口(带组,一次性临时密码
/// 回显可复制);行操作(编辑/启停/重置密码/解锁)拆见 admin_user_row.dart,
/// 表单拆件见 user_form_sheets/user_edit_sheet/temp_password_sheet。
/// require_system_admin。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import 'admin_user_row.dart';
import 'temp_password_sheet.dart';
import 'user_form_sheets.dart';

/// 页大小(web USERS_PAGE_SIZE 同款)。
const kAdminUsersPageSize = 20;

class AdminUsersPage extends StatefulWidget {
  const AdminUsersPage({super.key});

  @override
  State<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends State<AdminUsersPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  bool? _active; // null=全部
  final _items = <DirectoryUser>[];
  var _total = 0;
  var _loading = true;
  String? _error;
  var _reloadTag = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _reload);
  }

  Future<void> _reload() async {
    final tag = ++_reloadTag;
    setState(() => _loading = _items.isEmpty);
    try {
      final page = await session.api!.directory.listUsers(
        q: _search.text.trim(),
        isActive: _active,
        limit: kAdminUsersPageSize,
        offset: 0,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      _fail(tag, e.message);
    } catch (e) {
      _fail(tag, '$e');
    }
  }

  Future<void> _loadMore() async {
    final tag = _reloadTag;
    try {
      final page = await session.api!.directory.listUsers(
        q: _search.text.trim(),
        isActive: _active,
        limit: kAdminUsersPageSize,
        offset: _items.length,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() => _items.addAll(page.items));
    } catch (_) {}
  }

  void _fail(int tag, String message) {
    if (tag != _reloadTag || !mounted) return;
    setState(() {
      _error = message; // 403 detail 透传(非 admin 深链兜底)
      _loading = false;
    });
  }

  Future<void> _create() async {
    final created = await showCreateUserSheet(context);
    if (created == null || !mounted) return;
    await showTempPasswordSheet(context,
        password: created.temporaryPassword, title: '用户已创建');
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('用户'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt_1),
            tooltip: '新建用户',
            onPressed: _create,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '搜用户名 / 姓名 / 邮箱…',
                prefixIcon: Icon(Icons.search, size: 20),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 12),
                for (final (label, value) in const [
                  ('全部', null),
                  ('启用', true),
                  ('停用', false),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _active == value,
                      onSelected: (_) {
                        setState(() => _active = value);
                        _reload();
                      },
                    ),
                  ),
                const Spacer(),
                Text('共 $_total 名用户',
                    style: const TextStyle(fontSize: 11.5, color: Tk.subtle)),
                const SizedBox(width: 12),
              ],
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(message: _error!, onRetry: _reload);
    }
    if (_items.isEmpty) {
      return const EmptyState(message: '无用户');
    }
    return ListView.builder(
      itemCount: _items.length + (_items.length < _total ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child:
                OutlinedButton(onPressed: _loadMore, child: const Text('加载更多')),
          );
        }
        return AdminUserRow(user: _items[i], onChanged: _reload);
      },
    );
  }
}
