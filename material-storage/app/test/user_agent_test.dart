import 'package:flutter_test/flutter_test.dart';

import 'package:ms_app/core/api/user_agent.dart';

/// buildClientUserAgent 纯函数单测(使用统计 F2):
/// 版本三态(有/空串/null)× 平台注入(isIOS true/false)全组合,
/// 断言输出串与 usage-analytics 方案 §6 的样本字面一致。
/// isIOS 全部显式传参——测试环境不依赖 dart:io Platform 默认值。
void main() {
  test('有版本 × android', () {
    expect(buildClientUserAgent('0.1.11', isIOS: false),
        'msapp/0.1.11 (android)');
  });

  test('有版本 × ios', () {
    expect(
        buildClientUserAgent('0.1.11', isIOS: true), 'msapp/0.1.11 (ios)');
  });

  test('空串版本 × android(解析只依赖平台段)', () {
    expect(buildClientUserAgent('', isIOS: false), 'msapp/ (android)');
  });

  test('空串版本 × ios', () {
    expect(buildClientUserAgent('', isIOS: true), 'msapp/ (ios)');
  });

  test('null 版本 × android', () {
    expect(buildClientUserAgent(null, isIOS: false), 'msapp/ (android)');
  });

  test('null 版本 × ios', () {
    expect(buildClientUserAgent(null, isIOS: true), 'msapp/ (ios)');
  });
}
