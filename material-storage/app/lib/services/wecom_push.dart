/// WeComPush — 企业微信群机器人文件推送(官方两步流程,
/// https://developer.work.weixin.qq.com/document/path/99110):
///   ① POST `/cgi-bin/webhook/upload_media?key=<KEY>&type=file`
///      multipart/form-data,字段名 media,文件 ≤20MB → `{"errcode":0,"media_id":...}`
///   ② POST `/cgi-bin/webhook/send?key=<KEY>`
///      `{"msgtype":"file","file":{"media_id":...}}` → `{"errcode":0,"errmsg":"ok"}`
/// 推送成功由调用方(AppLog.clear)清空本地日志。
library;

import 'dart:io';

import 'package:dio/dio.dart';

import '../core/session.dart';
import 'app_log.dart';

class WeComPushException implements Exception {
  WeComPushException(this.stage, this.errcode, this.errmsg);

  final String stage;
  final int? errcode;
  final String errmsg;

  @override
  String toString() => 'WeComPush($stage) errcode=$errcode: $errmsg';
}

class WeComPush {
  WeComPush({String? webhookKey, String? apiBase, Dio? http})
    : key = webhookKey ?? defaultWebhookKey,
      base = (apiBase ?? 'https://qyapi.weixin.qq.com').replaceAll(
        RegExp(r'/+$'),
        '',
      ),
      _http =
          http ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ),
          );

  /// ⚠ 群机器人 webhook key 随仓库公开;若被滥用在群机器人设置里重置即可换 key。
  static const String defaultWebhookKey =
      'dd19928f-8904-446c-a8b6-df32f8de30c2';

  final String key;
  final String base;
  final Dio _http;

  /// 上传素材 → media_id(3 天有效)。
  Future<String> uploadMedia(File file) async {
    final rs = await _http.post<Map>(
      '$base/cgi-bin/webhook/upload_media',
      queryParameters: {'key': key, 'type': 'file'},
      data: FormData.fromMap({
        'media': await MultipartFile.fromFile(
          file.path,
          filename:
              'msapp_log'
              '_${DateTime.now().toIso8601String().replaceAll(RegExp(r'[-:.T]'), '').substring(0, 14)}'
              '.log',
        ),
      }),
    );
    final d = rs.data ?? const {};
    if (d['errcode'] != 0 || d['media_id'] == null) {
      throw WeComPushException(
        'upload_media',
        d['errcode'] as int?,
        '${d['errmsg']}',
      );
    }
    return d['media_id'] as String;
  }

  /// 发送文件类型消息。
  Future<void> sendFile(String mediaId) async {
    final rs = await _http.post<Map>(
      '$base/cgi-bin/webhook/send',
      queryParameters: {'key': key},
      data: {
        'msgtype': 'file',
        'file': {'media_id': mediaId},
      },
    );
    final d = rs.data ?? const {};
    if (d['errcode'] != 0) {
      throw WeComPushException('send', d['errcode'] as int?, '${d['errmsg']}');
    }
  }

  /// 发送文本类型消息(P10 身份标识用)。
  Future<void> sendText(String content) async {
    final rs = await _http.post<Map>(
      '$base/cgi-bin/webhook/send',
      queryParameters: {'key': key},
      data: {
        'msgtype': 'text',
        'text': {'content': content},
      },
    );
    final d = rs.data ?? const {};
    if (d['errcode'] != 0) {
      throw WeComPushException('send', d['errcode'] as int?, '${d['errmsg']}');
    }
  }

  /// 一键推送日志文件;返回 media_id 供展示。
  /// P10:已登录(session.me != null)先发一条 text 身份消息,企微群里先看到
  /// 是谁推的日志;身份消息失败只记日志、不阻断后续 file 推送。未登录(登录页
  /// 调试出口)维持只发 file。
  Future<String> pushLogFile(File file) async {
    final me = session.me;
    if (me != null) {
      try {
        await sendText('【移动端日志】用户 ${me.name}(uid ${me.id})· '
            '${_formatNow()}');
      } catch (e) {
        AppLog.error('wecom', '身份消息发送失败(不阻断日志文件推送)', e);
      }
    }
    final mediaId = await uploadMedia(file);
    await sendFile(mediaId);
    return mediaId;
  }

  /// 当前时刻 yyyy-MM-dd HH:mm(身份消息时间戳)。
  String _formatNow() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} '
        '${two(n.hour)}:${two(n.minute)}';
  }
}
