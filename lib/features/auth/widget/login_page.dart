// VVVPN: 客户端内嵌 webview 登录。
// 入口：empty profile 主页 → 用户点"登录" → 此页 → 内嵌 webview 加载
// https://vvvpn168.com/login → 用户在 webview 内输入邮箱密码 → web 提交到
// api.vvvpn168.com → 设 session cookie → web 跳 /dashboard → 我们检测 URL
// 变化 → 读 cookie → 调 /api/me/bundle → 拿订阅 URL → 自动 addProfile → 关页。

import 'dart:io' show Platform, Process;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:vvvpn_client/features/profile/data/profile_data_providers.dart';
import 'package:vvvpn_client/utils/custom_loggers.dart';

class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  static const _loginUrl = 'https://vvvpn168.com/login';
  static const _apiBase = 'https://api.vvvpn168.com';
  // 微软 WebView2 Evergreen Bootstrapper（~2 MB 引导器，自动拉本体）
  static const _webView2InstallerUrl =
      'https://go.microsoft.com/fwlink/p/?LinkId=2124703';
  // 登录成功后 web 默认跳的路径
  static final _successPathMatcher = RegExp(r'^/(dashboard|home)/?$');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Windows 上 flutter_inappwebview 走 Microsoft Edge WebView2 Runtime；
    // Runtime 缺失会让 webview 原生初始化失败、整进程闪退（无任何 Dart 侧异常
    // 能捕到）。这里在渲 InAppWebView 之前先 reg query 探一次，缺则换"装
    // WebView2"提示页，避免崩。
    final webView2Probe = useMemoized(_probeWebView2, const []);
    final probe = useFuture<bool>(webView2Probe);
    if (Platform.isWindows) {
      if (!probe.hasData) {
        return Scaffold(
          appBar: AppBar(title: const Text("登录到 VVVPN")),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      if (probe.data == false) {
        return _buildWebView2MissingPage(context);
      }
    }

    final theme = Theme.of(context);
    final loading = ValueNotifier<bool>(true);
    final processing = ValueNotifier<bool>(false);

    return Scaffold(
      appBar: AppBar(
        title: const Text("登录到 VVVPN"),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(url: WebUri(_loginUrl)),
            initialSettings: InAppWebViewSettings(
              isInspectable: false,
              javaScriptEnabled: true,
              thirdPartyCookiesEnabled: true,
              // 防止 webview 自己处理 clash:// 引发崩溃
              useShouldOverrideUrlLoading: true,
            ),
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              final url = navigationAction.request.url?.toString() ?? '';
              if (url.startsWith('clash://') || url.startsWith('hiddify://')) {
                // 不让 webview 加载 deeplink，由我们自己处理
                return NavigationActionPolicy.CANCEL;
              }
              return NavigationActionPolicy.ALLOW;
            },
            onLoadStart: (_, _) => loading.value = true,
            onLoadStop: (_, _) => loading.value = false,
            // Next.js 用 history.pushState 切路由，不会触发 onLoadStop —
            // 改用 onUpdateVisitedHistory 兜底 SPA 跳转
            onUpdateVisitedHistory: (controller, uri, _) async {
              if (uri == null) return;
              if (uri.host == 'vvvpn168.com' && _successPathMatcher.hasMatch(uri.path)) {
                if (processing.value) return;
                processing.value = true;
                await _handleLoginSuccess(context, ref);
              }
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: loading,
            builder: (_, isLoading, _) => isLoading
                ? LinearProgressIndicator(color: theme.colorScheme.primary, minHeight: 2)
                : const SizedBox.shrink(),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: processing,
            builder: (_, isProcessing, _) => isProcessing
                ? Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text("正在导入订阅…", style: TextStyle(color: Colors.white)),
                        ],
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// 检测到登录成功（webview URL 变 /dashboard）后：
  /// 1. 从 cookie store 读 api.vvvpn168.com 的 session
  /// 2. 调 /api/me/bundle 拿订阅 URL
  /// 3. profileRepo.upsertRemote(url) 自动添加 profile
  /// 4. 关闭本页回主页
  Future<void> _handleLoginSuccess(BuildContext context, WidgetRef ref) async {
    final loggy = Loggy<InfraLogger>('LoginPage');
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(_apiBase));
      if (cookies.isEmpty) {
        throw Exception('登录后 cookie 为空');
      }
      final cookieHeader = cookies.map((c) => '${c.name}=${c.value}').join('; ');

      final dio = Dio(BaseOptions(
        baseUrl: _apiBase,
        headers: {'Cookie': cookieHeader, 'Accept': 'application/json'},
        sendTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

      // 设备登记（MVP #3）：服务端 DeviceRegistryDO 原子准入；超限自动踢 LRU。
      // claim 失败不阻塞登录（log + 继续）；Linux/web 平台 enum 不支持，跳过。
      final platform = _vvvpnPlatformName();
      if (platform != null) {
        try {
          final deviceId = await _vvvpnGetOrCreateDeviceId();
          await dio.post<Map<String, dynamic>>(
            '/api/me/device',
            data: {'deviceId': deviceId, 'platform': platform},
          );
          loggy.info('device claim OK: $platform/$deviceId');
        } catch (e) {
          loggy.warning('device claim failed (non-fatal)', e);
        }
      }

      final resp = await dio.get<Map<String, dynamic>>('/api/me/bundle');
      final data = resp.data;
      if (data == null) throw Exception('bundle 响应为空');
      final sub = data['subscription'] as Map<String, dynamic>?;
      final subUrl = sub?['url'] as String?;
      if (subUrl == null || subUrl.isEmpty) {
        throw Exception('订阅 URL 缺失');
      }

      loggy.info('login OK, subscription URL: $subUrl');
      final repo = ref.read(profileRepositoryProvider).requireValue;
      final result = await repo.upsertRemote(subUrl).run();
      result.fold(
        (failure) => throw Exception('addProfile 失败: $failure'),
        (_) => null,
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('订阅导入成功')),
        );
        context.go('/home');
      }
    } catch (e, stack) {
      loggy.warning('handle login success failed', e, stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入订阅失败：$e')),
        );
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 设备 ID 与平台辅助（MVP #3）
//
// deviceId 持久化在 SharedPreferences，全 app 生命周期共用同一 id；
// 用户卸载重装 = 新 deviceId（视为新设备，合理）。
// 平台 enum 与服务端 schema 对齐：windows | macos | android | ios。
// Linux / web 暂不支持设备控制（API 不收）—— 返回 null 跳过 claim。
// ─────────────────────────────────────────────────────────────

const _vvvpnDeviceIdKey = 'vvvpn.device_id';

String? _vvvpnPlatformName() {
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  return null;
}

Future<String> _vvvpnGetOrCreateDeviceId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString(_vvvpnDeviceIdKey);
  if (existing != null && existing.isNotEmpty) return existing;
  final id = const Uuid().v4();
  await prefs.setString(_vvvpnDeviceIdKey, id);
  return id;
}

// ─────────────────────────────────────────────────────────────
// Windows WebView2 Runtime 探测
//
// 装机后 EdgeUpdate 会在以下三个注册表 key 之一写 'pv'（product version）：
//   - HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{GUID}  (64-bit 机器)
//   - HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}              (32-bit 机器)
//   - HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\{GUID}              (per-user 安装)
// GUID 是 WebView2 Evergreen Runtime 的固定值，微软官方文档指定。
// 任一存在即视为可用。reg.exe 是 Windows 内置，sub-50ms 返回；加 2s timeout 兜底。
// ─────────────────────────────────────────────────────────────

const _webView2RegGuid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';

Future<bool> _probeWebView2() async {
  if (!Platform.isWindows) return true;
  Future<bool> q(String key) async {
    try {
      final r = await Process.run('reg', ['query', key, '/v', 'pv'],
              runInShell: false)
          .timeout(const Duration(seconds: 2));
      return r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  if (await q(
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\' +
          _webView2RegGuid)) return true;
  if (await q(r'HKLM\SOFTWARE\Microsoft\EdgeUpdate\Clients\' +
      _webView2RegGuid)) return true;
  if (await q(r'HKCU\SOFTWARE\Microsoft\EdgeUpdate\Clients\' +
      _webView2RegGuid)) return true;
  return false;
}

Widget _buildWebView2MissingPage(BuildContext context) {
  return Scaffold(
    appBar: AppBar(
      title: const Text("需要安装 WebView2"),
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        onPressed: () =>
            context.canPop() ? context.pop() : context.go('/home'),
      ),
    ),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.extension_off_rounded, size: 48),
          const SizedBox(height: 16),
          const Text(
            "登录需要 Microsoft Edge WebView2 组件",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text(
            "当前 Windows 系统缺少 WebView2 Runtime，VVVPN 无法在 app 内打开登录页面。\n\n"
            "点击下方按钮去微软官网下载安装（~2 MB 引导器，自动拉本体约 120 MB）。\n"
            "装好后重新打开 VVVPN 即可登录。",
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.download_rounded),
            label: const Text("打开微软下载页"),
            onPressed: () => launchUrl(
              Uri.parse(LoginPage._webView2InstallerUrl),
              mode: LaunchMode.externalApplication,
            ),
          ),
        ],
      ),
    ),
  );
}
