/// 审计 CSV 导出落盘(B8 功能点 4):dio 带会话拉回的字节 → 临时文件 →
/// §6.1 落盘矩阵 other 列(Android=media_store_plus 写 Downloads/浣花视界,
/// iOS=share_plus 分享面板「存储到文件」)。
///
/// 钉子:**禁 url_launcher** —— 系统浏览器不带会话 cookie,export.csv 必 401;
/// 下载必须走 MsApi 的 Dio(cookie 持久化),本文件只管落盘。 savers/platform
/// 可注入(PC 单测零平台通道)。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../services/download_savers.dart';
import '../../services/downloads.dart' show defaultSavePlatform;
import '../../services/media_save.dart';

/// 落盘一份导出的 CSV,返回给用户的汇总文案(saveSummary 口径)。
/// [bytes] 为 export.csv 响应体;[filename] 取 Content-Disposition 或调用方拼。
Future<String> saveExportedCsv(
  List<int> bytes,
  String filename, {
  SavePlatform? platform,
  PlatformSavers? savers,
  Future<Directory> Function()? tempRoot,
}) async {
  final plat = platform ?? defaultSavePlatform();
  final plan = planSaveRoutes(platform: plat, kind: SaveAssetKind.other);
  final root = await (tempRoot ?? _defaultTempRoot)();
  final f = File('${root.path}/$filename');
  await f.writeAsBytes(bytes, flush: true);
  try {
    final outcomes = await runSavePlan(
      file: f,
      plan: plan,
      savers: savers ?? defaultSavers(),
    );
    return saveSummary(outcomes);
  } finally {
    // saveFile 搬运会删源(钉子);删不掉也不碍事(临时目录随系统回收)
    f.delete().ignore();
  }
}

/// CSV 文件名:Content-Disposition filename="audit-YYYYMMDD-HHMMSS.csv" 解析
/// 失败回落时间戳名(后端 admin.py:369 同款格式)。
String csvFilenameFromDisposition(String? disposition, DateTime now) {
  final m = RegExp(r'filename="([^"]+)"').firstMatch(disposition ?? '');
  if (m != null && m.group(1)!.isNotEmpty) return m.group(1)!;
  final t = now.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'audit-${t.year}${two(t.month)}${two(t.day)}-'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}.csv';
}

/// 导出字节快速嗅探:非空且以 UTF-8 BOM 或 `time,` 表头开头(契约自检,
/// 后端 admin.py:328-334;错拿 JSON 错误体时给可读文案)。
bool looksLikeCsv(List<int> bytes) {
  if (bytes.isEmpty) return false;
  const bom = [0xEF, 0xBB, 0xBF];
  if (bytes.length >= 3 && bytes[0] == bom[0] && bytes[1] == bom[1] && bytes[2] == bom[2]) {
    return true;
  }
  final head = utf8.decode(bytes.take(16).toList(), allowMalformed: true);
  return head.startsWith('time,');
}

Future<Directory> _defaultTempRoot() async {
  final base = await getTemporaryDirectory();
  final dir = Directory('${base.path}/exports');
  await dir.create(recursive: true);
  return dir;
}
