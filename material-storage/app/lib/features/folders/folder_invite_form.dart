/// FolderInviteForm — 敏感夹邀请表单(B6;F7):SubjectPicker + 等级
/// viewer/downloader + 有效期预设档位(web DUR_OPTIONS 实况),多主体
/// 逐个 POST;成功回调刷新成员列表。等级/有效期用 AppChip,吸底
/// ghost 返回 + 金主邀请。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/context_tk.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/buttons.dart';
import '../../widgets/pickers/subject_picker.dart';
import '../../widgets/toast.dart';

/// 敏感夹邀请有效期预设(web FolderInvitePanel DUR_OPTIONS 实况,值=秒;
/// 0=永久 → duration_seconds 省略)。
const kInviteDurationOptions = <(String, int)>[
  ('永久邀请', 0),
  ('1 小时', 3600),
  ('24 小时', 86400),
  ('7 天', 7 * 86400),
  ('30 天', 30 * 86400),
];

/// 邀请等级枚举(web InviteModal 同款)。
const kInviteLevels = <(String, String)>[
  ('viewer', '查看(viewer)'),
  ('downloader', '下载(downloader)'),
];

class FolderInviteForm extends StatefulWidget {
  const FolderInviteForm({
    super.key,
    required this.folder,
    required this.onDone,
  });

  final Folder folder;
  final VoidCallback onDone;

  @override
  State<FolderInviteForm> createState() => _FolderInviteFormState();
}

class _FolderInviteFormState extends State<FolderInviteForm> {
  var _subjects = const <Subject>[];
  var _level = 'viewer';
  var _durationIndex = 0; // 默认「永久邀请」(web useState(0) 同款)
  var _submitting = false;
  String? _error;

  Future<void> _submit() async {
    if (_subjects.isEmpty) {
      setState(() => _error = '请选至少一个主体');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final seconds = kInviteDurationOptions[_durationIndex].$2;
    var ok = 0;
    var fail = 0;
    String? firstError;
    for (final s in _subjects) {
      try {
        await session.api!.foldersOps.invite(
          widget.folder.id,
          userId: s.kind == SubjectKind.user ? s.id : null,
          groupId: s.kind == SubjectKind.group ? s.id : null,
          level: _level,
          durationSeconds: seconds > 0 ? seconds : null,
        );
        ok++;
      } catch (e) {
        fail++;
        firstError ??= '${s.name}: $e';
      }
    }
    if (!mounted) return;
    setState(() => _submitting = false);
    if (ok > 0) {
      toast(
        context,
        '邀请成功 $ok 个主体${fail > 0 ? ' · 失败 $fail' : ''}',
        tone: ToastTone.success,
      );
      widget.onDone();
      return;
    }
    setState(() => _error = firstError ?? '邀请失败');
  }

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    final labelStyle = TextStyle(fontSize: Tk.fzMd, color: tk.ink3);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '邀请 → ${widget.folder.name}',
          style: TextStyle(
            fontSize: Tk.fzRowTitle,
            fontWeight: FontWeight.w600,
            color: tk.ink,
          ),
        ),
        const SizedBox(height: Tk.spaceMd),
        Text('邀请主体(用户 / 用户组)', style: labelStyle),
        SubjectPicker(
          value: _subjects,
          onChanged: (v) => setState(() {
            _subjects = v;
            _error = null;
          }),
          preset: mePreset(),
        ),
        const SizedBox(height: Tk.spaceMd),
        Text('权限等级', style: labelStyle),
        const SizedBox(height: Tk.spaceXs),
        Wrap(
          spacing: Tk.spaceSm,
          runSpacing: Tk.spaceSm,
          children: [
            for (final (value, label) in kInviteLevels)
              AppChip(
                label: label,
                selected: _level == value,
                onTap: () => setState(() => _level = value),
              ),
          ],
        ),
        const SizedBox(height: Tk.spaceMd),
        Text('有效期', style: labelStyle),
        const SizedBox(height: Tk.spaceXs),
        Wrap(
          spacing: Tk.spaceSm,
          runSpacing: Tk.spaceSm,
          children: [
            for (var i = 0; i < kInviteDurationOptions.length; i++)
              AppChip(
                label: kInviteDurationOptions[i].$1,
                selected: _durationIndex == i,
                onTap: () => setState(() => _durationIndex = i),
              ),
          ],
        ),
        const SizedBox(height: Tk.spaceMd),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: tk.goldSoft,
            borderRadius: BorderRadius.circular(Tk.rSm),
          ),
          child: Text(
            '被邀请人将能${_level == 'downloader' ? '查看 + 下载' : '查看'}'
            '「${widget.folder.name}」内全部文件。'
            '${kInviteDurationOptions[_durationIndex].$2 > 0 ? '到期自动失效。' : ''}',
            style: TextStyle(fontSize: Tk.fzMd, color: tk.goldInk),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Tk.spaceSm),
            child: Text(
              _error!,
              style: TextStyle(fontSize: Tk.fzMd, color: tk.danger),
            ),
          ),
        const SizedBox(height: Tk.spaceLg),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : widget.onDone,
                child: const Text('返回'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PrimaryXl(
                onPressed: _submitting ? null : _submit,
                label: _submitting ? '邀请中…' : '邀请',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
