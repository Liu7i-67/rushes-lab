import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/features/projects/projects_page.dart';

void main() {
  test('项目页标题:stamp 未注入保持原标题,注入后在「项目」后追加最后编辑时间', () {
    // 未注入(本地 flutter run/test)→ 与旧标题完全一致
    expect(projectsTitle(null, ''), '项目');
    expect(projectsTitle('Evan', ''), '项目 · Evan');

    // 打包注入 → 项目 · 最后编辑 YYYY-MM-DD HH:mm [· 用户名]
    expect(projectsTitle(null, '2026-10-20 14:33'), '项目 · 最后编辑 2026-10-20 14:33');
    expect(
      projectsTitle('Evan', '2026-10-20 14:33'),
      '项目 · 最后编辑 2026-10-20 14:33 · Evan',
    );
  });
}
