/// FolderInviteForm — 敏感夹邀请表单(B6;自 folder_invite_sheet.dart 拆分):
/// SubjectPicker + 等级 viewer/downloader + 有效期预设档位(web DUR_OPTIONS 实况),
/// 多主体逐个 POST;成功回调刷新成员列表。
library;

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/pickers/subject_picker.dart';

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
  const FolderInviteForm({super.key, required this.folder, required this.onDone});

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
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text('邀请成功 $ok 个主体${fail > 0 ? ' · 失败 $fail' : ''}')));
      widget.onDone();
      return;
    }
    setState(() => _error = firstError ?? '邀请失败');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('邀请 → ${widget.folder.name}',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text('邀请主体(用户 / 用户组)',
                style: TextStyle(fontSize: 12, color: Tk.muted)),
            SubjectPicker(
              value: _subjects,
              onChanged: (v) => setState(() {
                _subjects = v;
                _error = null;
              }),
              preset: mePreset(),
            ),
            const SizedBox(height: 12),
            const Text('权限等级',
                style: TextStyle(fontSize: 12, color: Tk.muted)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                for (final (value, label) in kInviteLevels)
                  ChoiceChip(
                    label: Text(label),
                    selected: _level == value,
                    onSelected: (_) => setState(() => _level = value),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            const Text('有效期',
                style: TextStyle(fontSize: 12, color: Tk.muted)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (var i = 0; i < kInviteDurationOptions.length; i++)
                  ChoiceChip(
                    label: Text(kInviteDurationOptions[i].$1),
                    selected: _durationIndex == i,
                    onSelected: (_) => setState(() => _durationIndex = i),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Tk.accentFaint,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '被邀请人将能${_level == 'downloader' ? '查看 + 下载' : '查看'}'
                '「${widget.folder.name}」内全部文件。'
                '${kInviteDurationOptions[_durationIndex].$2 > 0 ? '到期自动失效。' : ''}',
                style: const TextStyle(fontSize: 11.5, color: Tk.muted),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12.5)),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting ? null : widget.onDone,
                  child: const Text('返回'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? '邀请中…' : '邀请'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
