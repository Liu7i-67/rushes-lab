/// RemotePickerSheet — 远程搜索弹层选择器(app-polish-3 C1):I2「点按弹层,
/// 弹层内可搜索、当前项高亮」推广到远程数据源。多选勾选即时回填 + 底部
/// 「完成(N)」提交(N=0 也可点 = 显式清空),单选点选即关;取消返回 null。
/// 250ms 防抖唯一实现 = [RemoteSearcher],subject_picker_sheet 共用不复制。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../buttons.dart';
import '../search_field.dart';
import '../sheet_scaffold.dart';

/// 弹「选择用户」远程搜索弹层(数据源 GET /users?q=;空 query 注入 preset)。
Future<List<UserBrief>?> showUserPickerSheet({
  required BuildContext context,
  String title = '选择用户',
  required List<UserBrief> initial,
  bool multiple = true,
  List<UserBrief>? preset,
}) {
  return _showRemotePickerSheet<UserBrief>(
    context: context, title: title, initial: initial, multiple: multiple,
    preset: preset, search: (q) => session.api!.users.searchUsers(q: q),
    idOf: (u) => u.id,
  );
}

/// 弹「选择用户组」远程搜索弹层(数据源 GET /groups?q=;组段无 preset)。
Future<List<GroupBrief>?> showGroupPickerSheet({
  required BuildContext context,
  String title = '选择用户组',
  required List<GroupBrief> initial,
  bool multiple = true,
}) {
  return _showRemotePickerSheet<GroupBrief>(
    context: context, title: title, initial: initial, multiple: multiple,
    search: (q) => session.api!.users.searchGroups(q: q),
    idOf: (g) => g.id,
  );
}

/// 泛型装配:选中集合外提为 ValueNotifier(列表与底部完成钮共用,不 dispose),本体+吸底钮一次组装,用户/组零复制。
Future<List<T>?> _showRemotePickerSheet<T>({
  required BuildContext context,
  required String title,
  required List<T> initial,
  required bool multiple,
  required Future<List<T>> Function(String q) search,
  required String Function(T) idOf,
  List<T>? preset,
}) {
  final selected = ValueNotifier<List<T>>(
      [...{for (final x in initial) idOf(x): x}.values]); // 按 id 防御性去重
  return showAppSheet<List<T>>(
    context: context,
    title: title,
    bottomActions: [
      if (multiple)
        ValueListenableBuilder<List<T>>(
          valueListenable: selected,
          // N=0 也放行:提交空集合 = 显式清空(需求口径)
          builder: (nctx, sel, _) => PrimaryXl(
              label: '完成(${sel.length})',
              onPressed: () => Navigator.of(nctx).pop(List<T>.of(sel))),
        ),
    ],
    child: _RemotePickerSheet<T>(
        search: search, idOf: idOf, selected: selected,
        multiple: multiple, preset: preset),
  );
}

class _RemotePickerSheet<T> extends StatefulWidget {
  const _RemotePickerSheet({
    required this.search,
    required this.idOf,
    required this.selected,
    required this.multiple,
    this.preset,
  });

  final Future<List<T>> Function(String q) search;
  final String Function(T) idOf;
  final ValueNotifier<List<T>> selected;
  final bool multiple;

  /// 空 query 并入候选的预置项(用户段「自己」;组段 null)。
  final List<T>? preset;

  @override
  State<_RemotePickerSheet<T>> createState() => _RemotePickerSheetState<T>();
}

class _RemotePickerSheetState<T> extends State<_RemotePickerSheet<T>> {
  final _query = TextEditingController();
  late final RemoteSearcher<T> _searcher;

  @override
  void initState() {
    super.initState();
    _searcher = RemoteSearcher<T>(widget.search)
      ..addListener(_rebuild)
      ..search('');
    widget.selected.addListener(_rebuild);
  }

  @override
  void dispose() {
    _searcher
      ..removeListener(_rebuild)
      ..dispose();
    widget.selected.removeListener(_rebuild);
    _query.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  /// 空 query 注入 preset(已出现在远程结果中的不重复;#114 同款防劫持)。
  List<T> get _visible {
    final opts = _searcher.options;
    final preset = widget.preset;
    if (_query.text.trim().isEmpty && preset != null) {
      final ids = opts.map(widget.idOf).toSet();
      return [...preset.where((p) => !ids.contains(widget.idOf(p))), ...opts];
    }
    return opts;
  }

  void _onTap(T item) {
    if (!widget.multiple) {
      Navigator.of(context).pop(<T>[item]); // 单选:点选即关(I1 口径)
      return;
    }
    final sel = List<T>.of(widget.selected.value);
    final id = widget.idOf(item);
    final i = sel.indexWhere((x) => widget.idOf(x) == id);
    if (i >= 0) { sel.removeAt(i); } else { sel.add(item); }
    widget.selected.value = sel;
  }

  @override
  Widget build(BuildContext context) {
    final options = _visible;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: Tk.spaceSm),
        child: SearchField(
            controller: _query, hintText: '搜索…', onChanged: _searcher.search),
      ),
      // 列表自封顶内滚(搜索框恒在顶;口径同 showPickerSheet,底线提到 200)
      Container(
        constraints: BoxConstraints(
            maxHeight: (MediaQuery.sizeOf(context).height * 0.45)
                .clamp(200.0, 420.0)),
        decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: BorderRadius.circular(Tk.rSm)),
        child: options.isEmpty
            ? remoteStatus(_searcher.fetching)
            : ListView.builder(
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, i) => remoteTileOf(
                    options[i],
                    selected: widget.selected.value.any(
                        (x) => widget.idOf(x) == widget.idOf(options[i])),
                    onTap: () => _onTap(options[i]))),
      ),
    ]);
  }
}

/// ── picker 族内部复用面(subject_picker_sheet 共用),勿在族外引用 ──

/// 加载/空态行(「搜索中…」/「无匹配」,与 I1/I2 文案口径一致)。
Widget remoteStatus(bool fetching) => Padding(
    padding: const EdgeInsets.all(Tk.spaceMd),
    child: Center(
        child: Text(fetching ? '搜索中…' : '无匹配',
            style: const TextStyle(fontSize: Tk.fzSm, color: Tk.muted))));

/// picker 族共用行构建(UserBrief → 用户行 / GroupBrief → 组行,按类型分发,
/// 视觉单点;选中 accent 高亮 + 对勾,I1 口径)。
Widget remoteTileOf(Object? item,
    {required bool selected, required VoidCallback onTap}) {
  final (leading, title, subtitle) = switch (item) {
    UserBrief u => (
        CircleAvatar(
            radius: 12, backgroundColor: Tk.accentSoft,
            child: Text(u.name.isEmpty ? '?' : u.name.characters.first,
                style: const TextStyle(fontSize: Tk.fzXs))),
        u.name,
        (u.username?.isNotEmpty ?? false) ? u.username : null,
      ),
    GroupBrief g => (
        const Icon(Icons.groups_outlined, size: 20),
        g.name,
        // memberCount null 时只显示 name,不加「0 人」
        g.memberCount != null ? '${g.memberCount} 人' : null,
      ),
    _ => throw UnsupportedError('remoteTileOf: 不支持的条目类型 $item'),
  };
  return ListTile(
    dense: true,
    leading: leading,
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: Tk.fzMd, color: selected ? Tk.accent : null,
            fontWeight: selected ? FontWeight.w600 : null)),
    subtitle: subtitle == null ? null : Text(subtitle,
        maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: Tk.fzXs, color: Tk.muted)),
    trailing:
        selected ? const Icon(Icons.check, size: 18, color: Tk.accent) : null,
    onTap: onTap,
  );
}

/// 250ms 防抖远程搜索器 —— picker 族唯一实现(user_picker/subject_picker 既有
/// 内联 _search 模式收敛于此):停顿 250ms 才发;自增 tag 丢弃过期响应;异常
/// 吞掉降级空结果(弹层显示「无匹配」);持有方 addListener → setState 收变化。
class RemoteSearcher<T> extends ChangeNotifier {
  RemoteSearcher(this.fetch);

  final Future<List<T>> Function(String q) fetch;
  Timer? _timer;
  var _tag = 0;
  var _fetching = false;

  /// 最近一次未过期响应。
  List<T> options = const [];

  /// 请求在途(含 250ms 停顿窗口;弹层据此显示「搜索中…」)。
  bool get fetching => _fetching;

  void search(String q) {
    _timer?.cancel();
    final tag = ++_tag;
    _fetching = true;
    notifyListeners();
    _timer = Timer(const Duration(milliseconds: 250), () async {
      final result = await fetch(q).catchError((_) => <T>[]);
      if (tag != _tag) return; // 过期响应丢弃
      options = result;
      _fetching = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
