/// app-polish-2(P2 批)iOS 通知静态断言(对应需求文档 2026-10-22-app-polish-2.md
/// J3 #8,测试功能点 9):services/notifier.dart 的 DarwinNotificationDetails
/// 补 sound/badge/interruptionLevel=active 与前台展示配置——静态代码扫描断言,
/// 真机通知展示验证留人工清单(iOS 后台 Dart 冻结传输属平台限制,文档记录)。
///
/// 套路:flutter test 以包根(material-storage/app)为 cwd,源码按相对路径
/// 直读(album_audio_permission_test 读 AndroidManifest 同法)。凡依赖
/// 「尚未存在的行为」的断言标注 TODO(app-polish2 J3): 现状应失败,交付后转绿。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // flutter test 以包根为 cwd,notifier 源码相对路径直读
  final src = File('lib/services/notifier.dart').readAsStringSync();

  test('J3 静态断言:DarwinNotificationDetails 含 sound/badge/'
      'interruptionLevel=active/前台展示配置', () {
    final start = src.indexOf('DarwinNotificationDetails(');
    // 已交付转绿(J3):_send 已挂非空 Darwin 详情(原为空配置)
    expect(start, greaterThanOrEqualTo(0), reason: '前置:_send 挂 Darwin 详情');
    // 取语句末尾(无更早的 ;,Android 分支只有逗号)圈定 Darwin 参数段
    final end = src.indexOf(';', start);
    final darwin = src.substring(start, end).toLowerCase();

    expect(darwin, contains('interruptionlevel'),
        reason: 'J3:interruptionLevel 申明(前台即时呈现)');
    expect(darwin, contains('active'),
        reason: 'J3:interruptionLevel=active(传输完成需醒目提示)');
    expect(darwin, contains('sound'), reason: 'J3:补 sound(完成提示音)');
    expect(darwin, contains('badge'), reason: 'J3:补 badge(前台展示配置)');
  });
}
