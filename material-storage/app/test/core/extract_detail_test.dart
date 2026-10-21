/// extractDetail 单测(§4.1):422 数组型 detail → 逐条 `loc: msg` 换行拼接;
/// 字符串型原样透出;对象型(B9 遗留清偿 P2-6)取 message/code 拼友好文案,
/// 皆缺回落 fallback(不再裸 toString 渲染原始 Map);无 detail 回落 fallback。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/core/api/ms_api.dart';

void main() {
  test('数组型(422 校验错):逐条 loc: msg,换行拼接', () {
    final out = extractDetail(const {
      'detail': [
        {
          'type': 'missing',
          'loc': ['body', 'old_password'],
          'msg': 'Field required',
          'input': null,
        },
        {
          'type': 'string_too_long',
          'loc': ['body', 'new_password'],
          'msg': 'String should have at most 128 characters',
        },
      ],
    }, '修改密码失败');
    expect(out, 'body.old_password: Field required\n'
        'body.new_password: String should have at most 128 characters');
  });

  test('loc 为空时只渲染 msg;非 Map 元素 toString', () {
    final out = extractDetail(const {
      'detail': [
        {'msg': 'boom'},
        'plain-entry',
      ],
    }, 'fallback');
    expect(out, 'boom\nplain-entry');
  });

  test('字符串型 detail 原样透出(登录失败中文文案)', () {
    expect(
      extractDetail(const {'detail': '用户名或密码错误'}, '登录失败'),
      '用户名或密码错误',
    );
  });

  test('对象型 detail:message/code 拼友好文案,不再裸 toString(B9 P2-6)', () {
    // 典型 {code, message} → message 优先,message+code 括注
    expect(
      extractDetail(const {'detail': {'code': 409, 'message': '并发冲突'}}, 'fb'),
      '并发冲突(409)',
    );
    // 仅 message → message
    expect(
      extractDetail(const {'detail': {'message': '资源不存在'}}, 'fb'),
      '资源不存在',
    );
    // msg 字段同义兜底
    expect(
      extractDetail(const {'detail': {'msg': 'boom'}}, 'fb'),
      'boom',
    );
    // 仅 code(结构化 token,如 create project 409 的 username_taken)→ token
    expect(
      extractDetail(const {'detail': {'code': 'username_taken'}}, 'fb'),
      'username_taken',
    );
    // 皆缺 → fallback(不再裸 toString 渲染原始 Map)
    expect(extractDetail(const {'detail': {'k': 'v'}}, 'fb'), 'fb');
    expect(extractDetail(null, 'fb'), 'fb');
    expect(extractDetail(const {'other': 1}, 'fb'), 'fb');
  });
}
