/// verify_wecom — 真实推送企业微信验证(PC 可跑)。
/// 生成一份样例日志文件 → 走 App 同款 WeComPush 链路 → 群里应收到 file 消息。
library;

import 'dart:io';

import 'package:ms_app/services/wecom_push.dart';

Future<void> main() async {
  final tmp = File(
      '${Directory.systemTemp.path}/msapp_log_verify_${DateTime.now().millisecondsSinceEpoch}.log');
  await tmp.writeAsString('''
2026-10-19T16:00:00 [INFO] [log] AppLog 就绪(file=/tmp/app.log)
2026-10-19T16:00:01 [INFO] [api] → POST /api/v1/auth/local/login
2026-10-19T16:00:01 [INFO] [api] ← 200 /api/v1/auth/local/login
2026-10-19T16:00:02 [INFO] [assets] 上传 IMG_0001.livp …
2026-10-19T16:00:03 [INFO] [api] ← 200 /api/v1/assets/uploads/u1/complete
2026-10-19T16:00:03 [INFO] [assets] ✓ 已上传:IMG_0001.livp
''');
  stdout.writeln('pushing ${tmp.path} (${await tmp.length()}B) …');
  final mediaId = await WeComPush().pushLogFile(tmp);
  stdout.writeln('PASS  upload_media → $mediaId;send file 消息已投递');
  stdout.writeln('请到企业微信群确认收到文件消息后,删除临时文件:rm ${tmp.path}');
}
