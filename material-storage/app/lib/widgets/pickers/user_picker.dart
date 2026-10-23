/// UserPicker — 用户搜索多/单选(B6 §9 pickers;web UserPicker 移动版):
/// 输入停顿 250ms 搜 GET /users?q=(留空返前 N),空 query 时注入 preset
/// (自己);stale 响应用自增 tag 丢弃。value = users.id UUID(#150 起)。
/// **表单场景请用 `UserPickerField`(弹层形态,app-polish-3 D4);本组件
/// 保留给需要内联常驻列表的场景与既有测试**。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';

class UserPicker extends StatefulWidget {
  const UserPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.multiple = true,
    this.preset,
    this.hint = '搜姓名 / 邮箱 / 用户名…',
  });

  /// 已选用户(value = users.id UUID;单选模式至多 1 个)。
  final List<UserBrief> value;
  final ValueChanged<List<UserBrief>> onChanged;
  final bool multiple;

  /// 空 query 时并入候选的预置项(调用方传「自己」;web preset 同语义)。
  final List<UserBrief>? preset;
  final String hint;

  @override
  State<UserPicker> createState() => _UserPickerState();
}

class _UserPickerState extends State<UserPicker> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  List<UserBrief> _options = const [];
  var _fetching = false;
  var _tag = 0;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 停顿 250ms 才发请求(web 同款);tag 自增丢弃过期响应。
  void _search(String q) {
    _debounce?.cancel();
    final tag = ++_tag;
    setState(() => _fetching = true);
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final users = await session.api!.users.searchUsers(q: q);
        if (tag != _tag || !mounted) return;
        setState(() {
          _options = users;
          _fetching = false;
        });
      } catch (_) {
        if (tag != _tag || !mounted) return;
        setState(() {
          _options = const [];
          _fetching = false;
        });
      }
    });
  }

  List<UserBrief> get _visibleOptions {
    // query 非空时不注入 preset(#114 修:防 preset 劫持搜索结果,'无匹配' 永不展示)
    if (_controller.text.trim().isEmpty && widget.preset != null) {
      final ids = _options.map((u) => u.id).toSet();
      return [...widget.preset!.where((u) => !ids.contains(u.id)), ..._options];
    }
    return _options;
  }

  void _toggle(UserBrief u) {
    var next = List<UserBrief>.of(widget.value);
    final has = next.any((x) => x.id == u.id);
    if (has) {
      next.removeWhere((x) => x.id == u.id);
    } else {
      // 单选 = 替换语义(新建项目管理员:选一个,再点别个换人)
      next = widget.multiple ? [...next, u] : [u];
    }
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final options = _visibleOptions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            hintText: widget.hint,
            prefixIcon: Icon(Icons.search, size: 20, color: tk.ink3),
            suffixIcon: _controller.text.isEmpty
                ? (_fetching
                      ? Padding(
                          padding: const EdgeInsets.all(10), // 参与加载圈尺寸计算
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null)
                : IconButton(
                    icon: Icon(Icons.clear, size: 18, color: tk.ink3),
                    onPressed: () {
                      _controller.clear();
                      _search('');
                    },
                  ),
          ),
          onChanged: _search,
        ),
        const SizedBox(height: Tk.spaceXs),
        ...valueChips(context),
        Container(
          constraints: const BoxConstraints(maxHeight: 180),
          decoration: BoxDecoration(
            border: Border.all(color: tk.line),
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          child: options.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(Tk.spaceMd),
                  child: Center(
                    child: Text(
                      _fetching ? '搜索中…' : '无匹配',
                      style: TextStyle(fontSize: Tk.fzMd, color: tk.ink3),
                    ),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, i) {
                    final u = options[i];
                    final selected = widget.value.any((x) => x.id == u.id);
                    return ListTile(
                      visualDensity: VisualDensity.compact,
                      selected: selected,
                      selectedTileColor: tk.goldSoft,
                      leading: CircleAvatar(
                        radius: 12,
                        backgroundColor: tk.goldSoft,
                        child: Text(
                          u.name.isEmpty ? '?' : u.name.characters.first,
                          style: TextStyle(
                            fontSize: Tk.fzXs,
                            color: tk.goldInk,
                          ),
                        ),
                      ),
                      title: Text(
                        u.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: Tk.fzRowTitle,
                          color: selected ? tk.goldInk : tk.ink,
                        ),
                      ),
                      subtitle: (u.username?.isNotEmpty ?? false)
                          ? Text(
                              u.username!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: Tk.fzMd,
                                color: tk.ink3,
                              ),
                            )
                          : null,
                      dense: true,
                      trailing: selected
                          ? Icon(Icons.check, size: 18, color: tk.gold)
                          : null,
                      onTap: () => _toggle(u),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 已选回显 chips(单选也展示,便于看清当前值/取消)。
  List<Widget> valueChips(BuildContext context) {
    if (widget.value.isEmpty) return const [];
    return [
      Wrap(
        spacing: Tk.spaceSm,
        runSpacing: 2,
        children: [
          for (final u in widget.value)
            InputChip(
              label: Text(
                u.name.isEmpty ? u.id : u.name,
                style: const TextStyle(fontSize: Tk.fzSm),
              ),
              visualDensity: VisualDensity.compact,
              onDeleted: () => _toggle(u),
            ),
        ],
      ),
      const SizedBox(height: Tk.spaceXs),
    ];
  }
}
