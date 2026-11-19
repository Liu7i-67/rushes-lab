/// PatToken / PatTokenCreated 契约对照用例(2026-11-19 settings-mcp-collapse
/// §9 App 5;测试用例包侧独立验收基线)。
///
/// 与并行包 A 自带 test/models/pat_token_test.dart 互为对照、互不重复:
/// 本文件聚焦边角样本——吊销+过期双标注、可选键整缺容忍(旧响应)、
/// Created 明文缺键回落空串、列表项永不要求明文键。核心字段对齐以包 A
/// 文件为准。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/models/models.dart';

void main() {
  group('PatToken.fromJson 边角样本', () {
    test('活跃行:从未使用(last_used_at=null)全字段对齐', () {
      final t = PatToken.fromJson(const {
        'id': 'aaaa0000-0000-0000-0000-000000000001',
        'name': '备用令牌',
        'token_prefix': 'mspat_00ff00',
        'created_at': '2026-11-19T08:00:00Z',
        'last_used_at': null,
        'expires_at': '2027-02-17T08:00:00Z',
        'revoked_at': null,
        'expired': false,
      });
      expect(t.lastUsedAt, isNull, reason: 'null=从未使用');
      expect(t.revokedAt, isNull);
      expect(t.expired, isFalse);
      expect(t.status, PatTokenStatus.active);
      expect(t.isActive, isTrue);
    });

    test('吊销+过期双标注:revoked_at 优先(expired 同为 true)', () {
      final t = PatToken.fromJson(const {
        'id': 'aaaa0000-0000-0000-0000-000000000002',
        'name': '双标注',
        'token_prefix': 'mspat_both',
        'created_at': '2026-01-01T00:00:00Z',
        'expires_at': '2026-06-01T00:00:00Z',
        'revoked_at': '2026-05-01T00:00:00Z',
        'expired': true,
      });
      expect(t.expired, isTrue);
      expect(t.status, PatTokenStatus.revoked, reason: '吊销优先于过期');
      expect(t.statusLabel, '已吊销');
    });

    test('可选键整缺容忍(revoked_at/last_used_at/expired 全缺)', () {
      final t = PatToken.fromJson(const {
        'id': 'aaaa0000-0000-0000-0000-000000000003',
        'name': '极简响应',
        'token_prefix': 'mspat_min',
        'created_at': '2026-11-19T08:00:00Z',
        'expires_at': '2099-02-17T08:00:00Z',
      });
      expect(t.lastUsedAt, isNull);
      expect(t.revokedAt, isNull);
      expect(t.expired, isFalse, reason: 'expired 缺省 false(后端默认)');
      expect(t.isActive, isTrue);
    });

    test('列表响应永不含明文:无 token 键解析不炸(仅 token_prefix 识别)', () {
      final j = const {
        'id': 'aaaa0000-0000-0000-0000-000000000004',
        'name': '无明文',
        'token_prefix': 'mspat_noplain',
        'created_at': '2026-11-19T08:00:00Z',
        'expires_at': '2099-02-17T08:00:00Z',
      };
      expect(j.containsKey('token'), isFalse, reason: '样本即契约:列表无明文键');
      final t = PatToken.fromJson(j);
      expect(t.tokenPrefix, 'mspat_noplain');
    });
  });

  group('PatTokenCreated.fromJson 边角样本', () {
    test('明文缺键回落空串(容错;页面按空值隐藏明文区块)', () {
      final c = PatTokenCreated.fromJson(const {
        'id': 'bbbb0000-0000-0000-0000-000000000001',
        'name': '缺明文',
        'token_prefix': 'mspat_c1',
        'expires_at': '2027-03-01T00:00:00Z',
      });
      expect(c.token, '', reason: '(j[\'token\'] ?? \'\') 容错口径');
      expect(c.tokenPrefix, 'mspat_c1');
    });

    test('一次性明文样本全字段对齐(id/name/token/prefix/过期)', () {
      final c = PatTokenCreated.fromJson(const {
        'id': 'bbbb0000-0000-0000-0000-000000000002',
        'name': 'ZCode CLI',
        'token': 'mspat_ONCE_ff01',
        'token_prefix': 'mspat_ONCE',
        'expires_at': '2027-02-17T08:00:00Z',
      });
      expect(c.id, 'bbbb0000-0000-0000-0000-000000000002');
      expect(c.name, 'ZCode CLI');
      expect(c.token, 'mspat_ONCE_ff01');
      expect(c.tokenPrefix, 'mspat_ONCE');
      expect(c.expiresAt, '2027-02-17T08:00:00Z');
    });
  });
}
