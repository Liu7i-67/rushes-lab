/// 清理 verify_dev 在 dev 遗留的 msapp_verify_*.livp(软删)。
/// 用法同 verify_dev(--base/--user/--pass)。
library;

import 'dart:io';

import 'package:ms_app/core/api/ms_api.dart';

Future<void> main(List<String> argv) async {
  var base = 'http://127.0.0.1:8200';
  var user = '';
  var pass = '';
  for (var i = 0; i < argv.length - 1; i++) {
    switch (argv[i]) {
      case '--base':
        base = argv[++i];
      case '--user':
        user = argv[++i];
      case '--pass':
        pass = argv[++i];
    }
  }
  final api = MsApi(baseUrl: base);
  await api.auth.login(user, pass);
  final projects = await api.projects.list();
  var n = 0;
  for (final p in projects) {
    final folders = await api.folders.list(p.id);
    for (final f in folders) {
      final page = await api.assets.list(f.id, limit: 100);
      for (final a in page.items) {
        if (a.filename.startsWith('msapp_verify_')) {
          await api.assets.delete(a.id);
          n++;
          stdout.writeln('deleted ${p.name}/${f.name}/${a.filename}');
        }
      }
    }
  }
  stdout.writeln('cleanup done: $n 个验证件已软删');
}
