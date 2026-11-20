/// Me.phone 解析(phone-bind 批,§7.4):可空解析,旧后端无此字段回落 null
/// (未绑定/null/有值三态,password_set 等既有字段行为零变化)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/models/models.dart';

void main() {
  test('Me.fromJson:phone 有值原样保留(完整号 D13)', () {
    final me = Me.fromJson(const {
      'id': 'u-1',
      'name': '甲',
      'phone': '13800138000',
    });
    expect(me.phone, '13800138000');
  });

  test('Me.fromJson:phone 为 null → null(已绑定列为空)', () {
    final me = Me.fromJson(const {'id': 'u-2', 'name': '乙', 'phone': null});
    expect(me.phone, isNull);
  });

  test('Me.fromJson:旧后端无 phone 字段 → null(SPA/App 先上线不炸)', () {
    final me = Me.fromJson(const {'id': 'u-3', 'name': '丙'});
    expect(me.phone, isNull);
  });

  test('Me.fromJson:既有闸门字段解析不受 phone 追加影响', () {
    final me = Me.fromJson(const {
      'id': 'u-4',
      'name': '丁',
      'must_change_password': true,
      'is_system_admin': true,
    });
    expect(me.mustChangePassword, isTrue);
    expect(me.isSystemAdmin, isTrue);
    expect(me.phone, isNull);
  });
}
