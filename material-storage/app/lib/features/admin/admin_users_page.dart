/// AdminUsersPage — 用户管理(B8 功能点 2;web AdminUsersPage 移动版):
/// 列表(q/is_active 筛选 + 服务端分页)+ 建号入口(带组,一次性临时密码
/// 回显可复制);行操作(编辑/启停/重置密码/解锁)拆见 admin_user_row.dart,
/// 表单拆件见 user_form_sheets/user_edit_sheet/temp_password_sheet。
/// require_system_admin。视觉:PageHeader + 搜索/筛选 chip 轨 + SectionCard 行卡。
library;

import 'dart:async';

import 'package:flutter/material.dart' hide Badge;

import '../../core/api/ms_api.dart';
import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_card.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/error_view.dart';
import '../../widgets/page_header.dart';
import '../../widgets/search_field.dart';
import '../../widgets/toast.dart';
import 'admin_auto_load.dart';
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

class _AdminUsersPageState extends State<AdminUsersPage>
    with AutoLoadScroll<AdminUsersPage> {
  final _search = TextEditingController();
  Timer? _debounce;
  bool? _active; // null=全部
  final _items = <DirectoryUser>[];
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;
  String? _error;
  var _reloadTag = 0;

  @override
  void initState() {
    super.initState(); // AutoLoadScroll:挂滚动监听
    _reload();
  }

  @override
  void onAutoLoad() => _loadMore();

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
      _fail(tag, errorMessage(e, '加载失败,请稍后重试'));
    }
  }

  /// 到底自动加载(F6):加载中/已取全守卫;失败 toast,滚动可再次触发。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _items.length >= _total) return;
    setState(() => _loadingMore = true);
    final tag = _reloadTag;
    try {
      final page = await session.api!.directory.listUsers(
        q: _search.text.trim(),
        isActive: _active,
        limit: kAdminUsersPageSize,
        offset: _items.length,
      );
      if (tag != _reloadTag || !mounted) return;
      setState(() {
        _items.addAll(page.items);
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      toast(context, errorMessage(e, '加载失败,请稍后重试'), tone: ToastTone.error);
    }
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
    await showTempPasswordSheet(
      context,
      password: created.temporaryPassword,
      title: '用户已创建',
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          PageHeader(
            back: true,
            title: '用户',
            subtitle: _loading ? null : '共 $_total 名用户',
            actions: [
              IconButton(
                icon: const Icon(Icons.person_add_alt_1),
                tooltip: '新建用户',
                onPressed: _create,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Tk.spacePage,
              Tk.spaceSm,
              Tk.spacePage,
              0,
            ),
            child: SearchField(
              controller: _search,
              hintText: '搜用户名 / 姓名 / 邮箱…',
              onChanged: _onSearchChanged,
            ),
          ),
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                Tk.spaceSm,
                Tk.spacePage,
                0,
              ),
              children: [
                for (final (label, value) in const [
                  ('全部', null),
                  ('启用', true),
                  ('停用', false),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: Tk.spaceSm),
                    child: AppChip(
                      label: label,
                      selected: _active == value,
                      onTap: () {
                        setState(() => _active = value);
                        _reload();
                      },
                    ),
                  ),
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
      return const EmptyState(icon: Icons.person_off_outlined, message: '无用户');
    }
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(
        Tk.spacePage,
        Tk.spaceMd,
        Tk.spacePage,
        Tk.space2xl,
      ),
      children: [
        SectionCard(
          children: [
            for (final u in _items) AdminUserRow(user: u, onChanged: _reload),
          ],
        ),
        if (_items.length < _total)
          AutoLoadFooter(loading: _loadingMore, onTap: _loadMore),
      ],
    );
  }
}
