/// ArtistAccountFields + ArtistResultView — 新建项目内嵌开通艺人账号(B6 方案
/// F3;自 new_project_sheet.dart 拆分):闸门 is_artist_account_creator 由调用方
/// 判定后挂载;登录名停顿 500ms 预检 GET /users/username-available(形状不合
/// 法不打请求,防 422;预检异常静默,提交期 409 兜底);两项全空 = 纯项目创建。
/// 结果面板:一次性初始密码回显可复制,仅此一次(F3-②)。
/// R1:面板处于新建项目 sheet 内,复制反馈改 CopyButton 就地图标切换
/// (SnackBar 被 sheet 遮挡不可见),登录名/初始密码两行就地生效。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../theme/tokens.dart';
import '../../widgets/copy_button.dart';

/// 登录名字符集(users.py username-available / ArtistAccountIn 同款)。
final RegExp kUsernamePattern = RegExp(r'^[a-zA-Z0-9._-]+$');

class ArtistAccountFields extends StatefulWidget {
  const ArtistAccountFields({
    super.key,
    required this.onChanged,
    required this.onNameFollow,
  });

  /// 任一输入变化后上报当前值(trim 后;sheet 据此决定是否带 artist_account)。
  final ValueChanged<({String username, String name})> onChanged;

  /// 艺人姓名变化(项目名未被手动编辑时跟随,web F3-① 同款;脱钩判断在调用方)。
  final ValueChanged<String> onNameFollow;

  @override
  State<ArtistAccountFields> createState() => _ArtistAccountFieldsState();
}

class _ArtistAccountFieldsState extends State<ArtistAccountFields> {
  final _username = TextEditingController();
  final _name = TextEditingController();
  Timer? _precheckTimer;

  // 冲突提示仅在「当前输入与已预检值一致」时显示——继续输入即隐藏,等下一轮预检
  String _checkedUsername = '';
  bool? _checkedAvailable;

  @override
  void dispose() {
    _precheckTimer?.cancel();
    _username.dispose();
    _name.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged((
        username: _username.text.trim(),
        name: _name.text.trim(),
      ));

  /// 登录名输入停顿 500ms 才预检;形状不合法(正则/长度)不打请求(防 422)。
  void _onUsernameChanged(String v) {
    _emit();
    _precheckTimer?.cancel();
    final username = v.trim();
    if (username.length < 2 ||
        username.length > 64 ||
        !kUsernamePattern.hasMatch(username)) {
      setState(() {
        _checkedUsername = '';
        _checkedAvailable = null;
      });
      return;
    }
    _precheckTimer = Timer(const Duration(milliseconds: 500), () async {
      try {
        final ok = await session.api!.users.usernameAvailable(username);
        if (!mounted) return;
        setState(() {
          _checkedUsername = username;
          _checkedAvailable = ok;
        });
      } catch (_) {
        // 预检只是尽力挡(网络/403 静默),不影响提交期 409 兜底(web 同口径)
      }
    });
  }

  bool get _conflict =>
      _checkedUsername.isNotEmpty &&
      _username.text.trim() == _checkedUsername &&
      _checkedAvailable == false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('开通艺人账号(可选,两项都留空 = 仅创建项目)',
            style: TextStyle(fontSize: 12, color: Tk.muted)),
        const SizedBox(height: 4),
        TextField(
          controller: _username,
          decoration: InputDecoration(
            isDense: true,
            labelText: '艺人登录名(字母/数字/._-,2-64 位)',
            border: const OutlineInputBorder(),
            errorText: _conflict
                ? '该登录名已被占用;若属该艺人本人请勿重复开通,可联系管理员加入项目成员'
                : null,
          ),
          onChanged: _onUsernameChanged,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          maxLength: 128,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '艺人姓名(填写后自动带入项目名称,手改项目名后脱钩)',
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onChanged: (v) {
            _emit();
            widget.onNameFollow(v);
          },
        ),
      ],
    );
  }
}

/// 一次性结果面板(F3-②:密码只展示这一次,唯一按钮收口;web 独立 Modal 同文案)。
class ArtistResultView extends StatelessWidget {
  const ArtistResultView({
    super.key,
    required this.username,
    required this.name,
    required this.password,
    required this.onFinish,
  });

  final String username;
  final String name;
  final String password;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_outline, size: 36, color: Tk.green),
          const SizedBox(height: 8),
          const Text('项目与艺人账号已创建',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          _copyRow(context, '登录名', username),
          _copyRow(context, '初始密码', password),
          const SizedBox(height: 4),
          Text(
              '密码仅展示这一次,关闭后无法再查;请复制并转交艺人($name),'
              '首次登录将要求修改密码。',
              style: const TextStyle(fontSize: 11.5, color: Tk.amber)),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onFinish,
              child: const Text('我已保存,进入项目'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _copyRow(BuildContext context, String label, String value) {
    return Row(children: [
      Text('$label:', style: const TextStyle(fontSize: 13.5)),
      const SizedBox(width: 6),
      Expanded(
        child: Text(value,
            style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace')),
      ),
      // R1:每行独立 CopyButton,成功就地名变 ✓(原「已复制」SnackBar 删除)
      CopyButton(
        text: value,
        tooltip: '复制$label',
        iconSize: 16,
        visualDensity: VisualDensity.compact,
      ),
    ]);
  }
}
