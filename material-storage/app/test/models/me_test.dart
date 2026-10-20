/// Me 模型解析(B1 新增字段):must_change_password / is_system_admin /
/// baidu_backup_enabled;缺省回落 false,解析行为与现役一致(容忍缺字段)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/models/models.dart';

void main() {
  test('Me.fromJson:三个 B1 闸门字段齐备', () {
    final me = Me.fromJson(const {
      'id': 'u-1',
      'name': '测试',
      'must_change_password': true,
      'is_system_admin': true,
      'baidu_backup_enabled': true,
    });
    expect(me.id, 'u-1');
    expect(me.name, '测试');
    expect(me.mustChangePassword, isTrue);
    expect(me.isSystemAdmin, isTrue);
    expect(me.baiduBackupEnabled, isTrue);
    expect(me.roleLabel, '系统管理员');
  });

  test('Me.fromJson:缺字段回落 false(存量 /me 响应兼容)', () {
    final me = Me.fromJson(const {'id': 'u-2', 'name': 'Evan'});
    expect(me.mustChangePassword, isFalse);
    expect(me.isSystemAdmin, isFalse);
    expect(me.baiduBackupEnabled, isFalse);
    expect(me.roleLabel, '成员');
  });

  test('Me.fromJson:name 为 null 不炸(与现役解析行为一致)', () {
    final me = Me.fromJson(const {'id': 'u-3', 'name': null});
    expect(me.name, '');
  });
}
