// VVVPN: 客户端内嵌 webview 登录。
// 入口：empty profile 主页 → 用户点"登录" → 此页 → 内嵌 webview 加载
// https://vvvpn168.com/login → 用户在 webview 内输入邮箱密码 → web 提交到
// api.vvvpn168.com → 设 session cookie → web 跳 /dashboard → 我们检测 URL
// 变化 → 读 cookie → 调 /api/me/bundle → 拿订阅 URL → 自动 addProfile → 关页。

import 'dart:io' show Directory, File, Platform;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:vvvpn_client/features/profile/data/profile_data_providers.dart';
import 'package:vvvpn_client/utils/custom_loggers.dart';

/// Windows WebView2 探测三态。
/// - [ok]：x64 WebView2 Runtime 已装、当前 x64 进程可用 —— 正常渲 InAppWebView。
/// - [missing]：常规 x64 Windows，没装任何 WebView2 Runtime —— 给 Evergreen
///   Bootstrapper 链接（~2MB，按 host arch 自动拉本体）。
/// - [armNeedsX64]：Win on ARM（Surface Pro X / Win11 Mac VM）系统自带 ARM64
///   Runtime，但 VVVPN 是 x64 程序、必须配 x64 Runtime —— 提示用户去开发者
///   下载页**显式选 x64 standalone**（bootstrapper 在 ARM 系统会装 ARM64 → 无效）。
enum WebView2Status { ok, missing, armNeedsX64 }

class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  static const _loginUrl = 'https://vvvpn168.com/login';
  static const _apiBase = 'https://api.vvvpn168.com';
  // 微软 WebView2 Evergreen Bootstrapper（~2 MB，按 host arch 自动拉本体）
  static const _webView2BootstrapperUrl =
      'https://go.microsoft.com/fwlink/p/?LinkId=2124703';
  // 开发者下载页（ARM 用户必须从这里选 x64 standalone，不能用上面 bootstrapper）
  static const _webView2DevPageUrl =
      'https://developer.microsoft.com/en-us/microsoft-edge/webview2/';
  // 登录成功后 web 默认跳的路径
  static final _successPathMatcher = RegExp(r'^/(dashboard|home)/?$');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Windows: 进 LoginPage 第一件事是探测 x64 WebView2 Runtime 是否可用。
    // 不可用就换提示页，避免 InAppWebView 创建时原生 COM 装载失败把整进程
    // 带崩（Dart try/catch 接不住）。retryTick 让用户装完 runtime 后点重试
    // 重新探测，不用关 app。
    final retryTick = useState(0);
    final probeFuture = useMemoized(_probeWebView2, [retryTick.value]);
    final probe = useFuture<WebView2Status>(probeFuture);
    if (Platform.isWindows) {
      if (!probe.hasData) {
        return Scaffold(
          appBar: AppBar(title: const Text("登录到 VVVPN")),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      if (probe.data != WebView2Status.ok) {
        return _buildWebView2NeededPage(
          context,
          status: probe.data!,
          onRetry: () => retryTick.value++,
        );
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
// Windows WebView2 Runtime 探测（arch-aware）
//
// 关键事实：
// - VVVPN.exe 是 x64 程序
// - x64 WebView2 Runtime 装在 C:\Program Files (x86)\Microsoft\EdgeWebView\
//   （Microsoft 约定：EdgeUpdate 是 32-bit、所有 x86/x64 runtime 都进 (x86) 路径）
// - ARM64 WebView2 Runtime 装在 C:\Program Files\Microsoft\EdgeWebView\
// - Win11 ARM 系统预装 ARM64 runtime，x64 进程**用不了**，必须额外装 x64 standalone
// - Evergreen Bootstrapper 只装 host arch 那份 → 对 ARM 用户没用
//
// 探测策略：直接看 x64 安装路径下有没有 msedgewebview2.exe。
// - 有 → ok
// - 没有 + 系统是 ARM（看 C:\Windows\SysArm32 是否存在）→ armNeedsX64
// - 没有 + 系统是 x64 → missing
// ─────────────────────────────────────────────────────────────

const _webView2X64InstallDir =
    r'C:\Program Files (x86)\Microsoft\EdgeWebView\Application';
const _armWindowsMarker = r'C:\Windows\SysArm32';

Future<WebView2Status> _probeWebView2() async {
  if (!Platform.isWindows) return WebView2Status.ok;
  if (await _hasX64WebView2()) return WebView2Status.ok;
  if (await _isArmWindows()) return WebView2Status.armNeedsX64;
  return WebView2Status.missing;
}

Future<bool> _hasX64WebView2() async {
  try {
    final dir = Directory(_webView2X64InstallDir);
    if (!await dir.exists()) return false;
    await for (final entry in dir.list()) {
      if (entry is Directory) {
        if (await File(p.join(entry.path, 'msedgewebview2.exe')).exists()) {
          return true;
        }
      }
    }
  } catch (_) {}
  return false;
}

Future<bool> _isArmWindows() async {
  try {
    return await Directory(_armWindowsMarker).exists();
  } catch (_) {
    return false;
  }
}

Widget _buildWebView2NeededPage(
  BuildContext context, {
  required WebView2Status status,
  required VoidCallback onRetry,
}) {
  // 两态共用页面骨架，只换文案 + 按钮目标
  final (title, subtitle, body, buttonLabel, buttonUrl) = switch (status) {
    WebView2Status.missing => (
      "需要安装 WebView2",
      "当前 Windows 缺少 Microsoft Edge WebView2 Runtime",
      "VVVPN 用 WebView2 在 app 内打开登录页。点下方按钮去微软官网下载 "
          "Evergreen 引导器（~2 MB，会自动拉本体约 120 MB）。装好后回这里点「重试」即可。",
      "下载 WebView2 (~2 MB 引导器)",
      LoginPage._webView2BootstrapperUrl,
    ),
    WebView2Status.armNeedsX64 => (
      "Windows on ARM 需要装 x64 版 WebView2",
      "你在 ARM Windows 上（Surface Pro X / Win11 Mac VM 等）",
      "VVVPN 是 x64 程序，必须配 x64 版 WebView2 Runtime。系统自带的是 ARM64 版，"
          "x64 进程用不了。\n\n"
          "请按以下步骤：\n"
          "1. 点下方按钮打开微软官方下载页\n"
          "2. 找到「Evergreen Standalone Installer」一节\n"
          "3. 选 **x64**（不是 ARM64！不是 Bootstrapper！）下载\n"
          "4. 装好后回这里点「重试」",
      "打开微软下载页",
      LoginPage._webView2DevPageUrl,
    ),
    WebView2Status.ok => throw StateError('ok 不该进这里'),
  };

  return Scaffold(
    appBar: AppBar(
      title: Text(title),
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
          Text(
            subtitle,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          Text(body),
          const SizedBox(height: 24),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.download_rounded),
                label: Text(buttonLabel),
                onPressed: () => launchUrl(
                  Uri.parse(buttonUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: const Text("重试"),
                onPressed: onRetry,
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
