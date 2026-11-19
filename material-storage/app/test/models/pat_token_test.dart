/// PatToken / PatTokenCreated / UserPrefs 模型解析(2026-11-19 App 包A;
/// 契约 §9 用例 5:字段与后端 TokenOut / TokenCreatedOut / PreferencesOut
/// 对齐,明文字段解析正确;缺字段容忍回落)。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/models/models.dart';

void main() {
  test('PatToken.fromJson:后端 TokenOut 全字段对齐', () {
    final t = PatToken.fromJson(const {
      'id': '0b6b2b3e-1111-2222-3333-444455556666',
      'name': '我的 ZCode',
      'token_prefix': 'mspat_ab12cd',
      'created_at': '2026-11-19T10:00:00Z',
      'last_used_at': '2026-11-19T12:30:00Z',
      'expires_at': '2099-02-17T10:00:00Z',
      'revoked_at': null,
      'expired': false,
    });
    expect(t.id, '0b6b2b3e-1111-2222-3333-444455556666'); // UUID → String
    expect(t.name, '我的 ZCode');
    expect(t.tokenPrefix, 'mspat_ab12cd');
    expect(t.lastUsedAt, isNotNull);
    expect(t.revokedAt, isNull);
    expect(t.expired, isFalse);
    expect(t.status, PatTokenStatus.active);
    expect(t.statusLabel, '有效');
    expect(t.isActive, isTrue);
  });

  test('PatToken.status:吊销优先于过期;expired 缺失按 expires_at 派生', () {
    final revoked = PatToken.fromJson(const {
      'id': 'id-1',
      'name': 'n',
      'token_prefix': 'p',
      'created_at': '2026-11-19T10:00:00Z',
      'expires_at': '2099-02-17T10:00:00Z',
      'revoked_at': '2026-11-19T11:00:00Z',
    });
    expect(revoked.status, PatTokenStatus.revoked);
    expect(revoked.statusLabel, '已吊销');

    final expired = PatToken.fromJson(const {
      'id': 'id-2',
      'name': 'n',
      'token_prefix': 'p',
      'created_at': '2020-01-01T10:00:00Z',
      'expires_at': '2021-01-01T10:00:00Z',
    });
    expect(expired.status, PatTokenStatus.expired);
    expect(expired.statusLabel, '已过期');
    expect(expired.isActive, isFalse);
  });

  test('PatTokenCreated.fromJson:明文 token 只在此响应出现,字段齐备', () {
    final c = PatTokenCreated.fromJson(const {
      'id': 'id-3',
      'name': 'CI',
      'token': 'mspat_plaintext_once',
      'token_prefix': 'mspat_pl',
      'expires_at': '2027-02-17T10:00:00Z',
    });
    expect(c.token, 'mspat_plaintext_once');
    expect(c.tokenPrefix, 'mspat_pl');
    expect(c.name, 'CI');
    expect(c.expiresAt, '2027-02-17T10:00:00Z');
  });

  test('UserPrefs.fromJson:缺字段回落 false(无偏好行用户语义)', () {
    expect(UserPrefs.fromJson(const {}).folderTreeDefaultCollapsed, isFalse);
    expect(
      UserPrefs.fromJson(const {'folder_tree_default_collapsed': true})
          .folderTreeDefaultCollapsed,
      isTrue,
    );
  });
}
