/// phone-bind 批测试共用假 AuthApi(testWidgets 用,照 api_harness.dart 的
/// FakeXxxApi 记录式桩先例):覆写 AuthApi 四个手机号端点 + me(),记录入参、
/// 结果可编排(staged 为 Exception 即抛;send 端点可编排返回的 retry_after)。
/// [FakePhoneMsApi] 装配注入全局 session(测试收尾自行清理 session.api/me)。
library;

import 'package:ms_app/core/api/auth_api.dart';
import 'package:ms_app/core/api/ms_api.dart';
import 'package:ms_app/core/session.dart';
import 'package:ms_app/models/models.dart';

class FakeAuthApi extends AuthApi {
  FakeAuthApi(super.api);

  // ── 调用记录 ──
  final sendBindCalls = <String>[];
  final bindCalls = <({String phone, String code})>[];
  final sendResetCalls = <String>[];
  final confirmCalls = <({String phone, String code})>[];
  int meCalls = 0;

  // ── 结果编排(Exception 即抛;send 端点编排 retry_after 返回值)──
  Object? sendBindStaged;
  int sendBindRetry = 0;
  Object? bindStaged;
  Object? sendResetStaged;
  int sendResetRetry = 0;
  Object? confirmStaged;
  PhoneResetResult confirmResult = PhoneResetResult(
    username: 'jia',
    email: 'jia@x.com',
    name: '甲',
    newPassword: 'Rand0m-Pass12',
  );
  Me meResult = Me(id: 'u-1', name: '甲');

  @override
  Future<int> sendPhoneBindCode(String phone) async {
    sendBindCalls.add(phone);
    if (sendBindStaged is Exception) throw sendBindStaged!;
    return sendBindRetry;
  }

  @override
  Future<String> bindPhone(String phone, String code) async {
    bindCalls.add((phone: phone, code: code));
    if (bindStaged is Exception) throw bindStaged!;
    return phone;
  }

  @override
  Future<int> sendPhoneResetCode(String phone) async {
    sendResetCalls.add(phone);
    if (sendResetStaged is Exception) throw sendResetStaged!;
    return sendResetRetry;
  }

  @override
  Future<PhoneResetResult> confirmPhoneReset(String phone, String code) async {
    confirmCalls.add((phone: phone, code: code));
    if (confirmStaged is Exception) throw confirmStaged!;
    return confirmResult;
  }

  @override
  Future<Me> me() async {
    meCalls++;
    return meResult;
  }
}

/// 装配 FakeAuthApi 的假 MsApi(只覆写 auth 域;其余域不触网)。
class FakePhoneMsApi extends MsApi {
  FakePhoneMsApi() : super(baseUrl: 'http://phone.test.local');

  late final _auth = FakeAuthApi(this);

  @override
  FakeAuthApi get auth => _auth;
}

/// 注入全局 session 并返回假 auth 域;调用方 addTearDown 清理 session。
FakeAuthApi installFakeAuthApi({Me? me}) {
  final api = FakePhoneMsApi();
  session.api = api;
  session.me = me;
  return api.auth;
}
