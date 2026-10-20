/// verify_dev — dev 环境真连通验证(PC 可跑,纯 Dart 无插件依赖)。
///
/// 用法(先建 ssh 隧道把 dev API 转发到本机):
///   ssh -N -L 8200:127.0.0.1:`<dev-api-port>` hh2 &
///   dart run tool/verify_dev.dart --base http://127.0.0.1:8200 \
///        --user evan --pass '...'
///
/// 步骤(全部真实 API,末步自清理软删):
///   登录 → /me → 项目列表 → 首项目文件夹树 → 首个文件夹上传
///   1×(jpeg+mov) livp → download-link → 下载回读字节一致 → 解包校验 → 软删。
library;

import 'dart:convert';
import 'dart:io';

import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/services/livp.dart';

// 1x1 JPEG(合法可解码静态帧,缩略图 worker 可处理)
const _jpegB64 =
    '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwh'
    'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAB'
    'AAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgED'
    'AwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYG'
    'RolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJip'
    'KTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx'
    '8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD3+iiigD//2Q==';

void _ok(String step) => stdout.writeln('PASS  $step');

Future<void> _fail(String step, Object e) async {
  stdout.writeln('FAIL  $step: $e');
  exit(1);
}

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
  if (user.isEmpty || pass.isEmpty) {
    stdout.writeln('need --user/--pass');
    exit(2);
  }

  final api = MsApi(baseUrl: base);
  try {
    final me = await api.auth.login(user, pass);
    _ok('login → ${me.name}(${me.id})');

    final meAgain = await api.auth.me();
    _ok('me → ${meAgain.name}');

    final projects = await api.projects.list();
    _ok('projects → ${projects.length} 个:${projects.take(5).map((p) => p.name).join('/')}');
    if (projects.isEmpty) throw StateError('无可见项目');

    final folders = await api.folders.list(projects.first.id);
    _ok('folders → ${folders.length} 个');
    final target = folders.isEmpty ? null : folders.first;
    if (target == null) throw StateError('项目无文件夹,无法继续上传验证');

    final before = await api.assets.list(target.id);
    _ok('assets(${target.name}) → 现有 ${before.total} 个');

    final jpg = base64Decode(_jpegB64);
    final mov = List<int>.generate(4096, (i) => i % 256);
    final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[-:.T]'), '').substring(0, 14);
    final name = 'msapp_verify_$ts.livp';
    final payload = LivpService.pack(
      imageBytes: jpg,
      imageExt: 'jpg',
      videoBytes: mov,
      videoExt: 'mov',
      baseName: 'VERIFY',
    );

    final asset = await api.assets.uploadBytes(
      folderId: target.id,
      filename: name,
      bytes: payload,
      onPartsDone: (d, t) => stdout.writeln('      分片 $d/$t'),
    );
    _ok('upload → ${asset.filename}(${asset.sizeBytes}B)');

    final after = await api.assets.list(target.id);
    _ok('assets → ${after.total} 个(+${after.total - before.total})');

    final url = await api.assets.downloadLink(asset.id);
    final save = '${Directory.systemTemp.path}/$name';
    final f = await api.assets.downloadTo(url, save);
    final back = await f.readAsBytes();
    if (back.length != payload.length) {
      throw StateError('回读字节不符:${back.length} != ${payload.length}');
    }
    var same = true;
    for (var i = 0; i < payload.length; i++) {
      if (payload[i] != back[i]) {
        same = false;
        break;
      }
    }
    if (!same) throw StateError('回读字节内容不一致');
    _ok('download → 回读 ${back.length}B 与上传载荷逐字节一致');

    final parts = LivpService.decode(back);
    _ok('livp unpack → ${parts.image.name}'
        '${parts.video != null ? ' + ${parts.video!.name}' : ''}');

    await api.assets.delete(asset.id);
    _ok('cleanup → 已软删 $name(dev 回收站可彻底清除)');

    stdout.writeln('\nALL PASS — dev 环境全链路(登录/浏览/livp 上传下载)验证通过');
  } catch (e) {
    await _fail('verify', e);
  }
}
