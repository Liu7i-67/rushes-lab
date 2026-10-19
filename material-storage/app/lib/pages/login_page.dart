import 'package:flutter/material.dart';

import '../api/ms_api.dart';
import '../main.dart'
    show apiOf, initPersistence, kApiPresets, loadBaseUrl, saveBaseUrl;

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _baseUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// 载入持久化的后端地址(无记录回落 dev 预设);已有会话则直接进入。
  Future<void> _restore() async {
    _baseUrl.text = await loadBaseUrl();
    if (!mounted) return;
    setState(() {}); // 刷新预设选中态
    await initPersistence();
    try {
      final api = apiOf(_baseUrl.text.trim());
      final me = await api.me();
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/projects', arguments: me);
    } catch (_) {/* 未登录属正常态 */}
  }

  /// 当前地址命中哪个预设;不命中 = custom
  String get _selection {
    final url = _baseUrl.text.trim();
    for (final e in kApiPresets.entries) {
      if (e.value == url) return e.key;
    }
    return 'custom';
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final url = _baseUrl.text.trim();
    try {
      final api = apiOf(url);
      final me = await api.login(
        _username.text.trim(),
        _password.text,
      );
      // 登录成功才落盘,避免误存手滑地址
      await saveBaseUrl(url);
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/projects', arguments: me);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '网络错误:$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('素材库', textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                Text('实况照片 livp 通道 · MVP',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 32),

                // ── 后端环境切换:dev / prod 预设 + 自定义(手填外网/隧道口)──
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'dev', label: Text('dev')),
                    ButtonSegment(value: 'prod', label: Text('prod')),
                    ButtonSegment(value: 'custom', label: Text('自定义')),
                  ],
                  selected: {_selection},
                  onSelectionChanged: (sel) {
                    final v = sel.first;
                    setState(() {
                      if (v != 'custom') _baseUrl.text = kApiPresets[v]!;
                    });
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _baseUrl,
                  onChanged: (_) => setState(() {}), // 手动编辑 → 切到自定义态
                  decoration: const InputDecoration(
                      labelText: '服务地址', prefixIcon: Icon(Icons.dns_outlined)),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                      labelText: '用户名 / 邮箱',
                      prefixIcon: Icon(Icons.person_outline)),
                  autocorrect: false,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  onSubmitted: (_) => _busy ? null : _login(),
                  decoration: const InputDecoration(
                      labelText: '密码', prefixIcon: Icon(Icons.lock_outline)),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _login,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
