/// UserPrefs.fromJson 契约用例(2026-11-19 settings-mcp-collapse §6/§9 App 5):
/// 服务端 snake_case `folder_tree_default_collapsed` → 模型 camelCase
/// `folderTreeDefaultCollapsed`;GET/PUT 恒回全字段、缺省补默认值 false,
/// 模型对缺键容忍回落 false(与 Me.fromJson 缺字段回落口径一致)。
/// 纯解析用例:无网络、无异步。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/models/models.dart';

void main() {
  test('UserPrefs.fromJson:true 原样透传(snake_case → camelCase)', () {
    final p = UserPrefs.fromJson(
      const {'folder_tree_default_collapsed': true},
    );
    expect(p.folderTreeDefaultCollapsed, isTrue);
  });

  test('UserPrefs.fromJson:false 原样透传(默认态)', () {
    final p = UserPrefs.fromJson(
      const {'folder_tree_default_collapsed': false},
    );
    expect(p.folderTreeDefaultCollapsed, isFalse);
  });

  test('UserPrefs.fromJson:缺键回落 false(GET 恒回全字段,容错口径)', () {
    final p = UserPrefs.fromJson(const {});
    expect(p.folderTreeDefaultCollapsed, isFalse);
  });

  test('UserPrefs 构造缺省=false(与后端 DEFAULT_PREFS 对齐)', () {
    expect(const UserPrefs().folderTreeDefaultCollapsed, isFalse);
  });
}
