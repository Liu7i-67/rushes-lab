import 'package:flutter_test/flutter_test.dart';
import 'package:ms_app/main.dart'
    show kApiPresets, kDefaultBaseUrl, loadBaseUrl, saveBaseUrl;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('默认 dev 外网入口;手动切换 prod/自定义后持久化', () async {
    expect(kDefaultBaseUrl, kApiPresets['dev']);
    expect(kApiPresets['dev'], 'http://47.108.196.211:8080');
    expect(kApiPresets['prod'], 'https://bucket.taoxiplan.com');

    // 无记录 → dev(外网,手机直连可达)
    expect(await loadBaseUrl(), kApiPresets['dev']);

    // 切 prod(HTTPS 域名)→ 重启后仍是 prod
    await saveBaseUrl(kApiPresets['prod']!);
    expect(await loadBaseUrl(), kApiPresets['prod']);

    // 自定义(如内网入口/PC 隧道口)→ 持久化
    await saveBaseUrl('http://127.0.0.1:8200');
    expect(await loadBaseUrl(), 'http://127.0.0.1:8200');
  });
}
