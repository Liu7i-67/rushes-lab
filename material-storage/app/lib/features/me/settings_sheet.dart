/// settings_sheet — 外观设置面板(§5.4 / §6 F1):
/// 三档 跟随系统 / 深色 / 浅色;选择即时 [ThemeController.setPref],
/// 面板不关闭;说明文案随系统明暗变化。本包只做外观,不掺传输设置。
library;

import 'package:flutter/material.dart';

import '../../theme/context_tk.dart';
import '../../theme/theme_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/section_label.dart';

/// 打开外观设置弹层;[controller] 供单测注入,生产用全局单例。
Future<void> showAppearanceSheet(
  BuildContext context, {
  ThemeController? controller,
}) async {
  final c = controller ?? themeController;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AppearanceSheet(controller: c),
  );
}

class _AppearanceSheet extends StatelessWidget {
  const _AppearanceSheet({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    final tk = context.tk;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: Tk.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Tk.spacePage,
                0,
                Tk.spacePage,
                Tk.spaceXs,
              ),
              child: Text(
                '设置',
                style: TextStyle(
                  fontSize: Tk.fzSection,
                  fontWeight: FontWeight.w600,
                  color: tk.ink,
                ),
              ),
            ),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final t = context.tk;
                final systemDark =
                    MediaQuery.platformBrightnessOf(context) == Brightness.dark;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SectionLabel(title: '外观'),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Tk.spacePage,
                      ),
                      child: AppSegmented<ThemePref>(
                        segments: const [
                          Segment(value: ThemePref.system, label: '跟随系统'),
                          Segment(value: ThemePref.dark, label: '深色'),
                          Segment(value: ThemePref.light, label: '浅色'),
                        ],
                        value: controller.pref,
                        onChanged: (v) => controller.setPref(v),
                      ),
                    ),
                    const SizedBox(height: Tk.spaceSm),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Tk.spacePage,
                      ),
                      child: Text(
                        '跟随系统时，随设备外观自动切换；'
                        '当前系统为${systemDark ? '深色' : '浅色'}。',
                        style: TextStyle(
                          fontSize: Tk.fzMd,
                          height: 1.5,
                          color: t.ink3,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
