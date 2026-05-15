// VVVPN: 客户端内嵌 webview 登录。
// 入口：empty profile 主页 → 用户点"登录" → 此页 → 内嵌 webview 加载
// https://vvvpn168.com/login → 用户在 webview 内输入邮箱密码 → web 提交到
// api.vvvpn168.com → 设 session cookie → web 跳 /dashboard → 我们检测 URL
// 变化 → 读 cookie → 调 /api/me/bundle → 拿订阅 URL → 自动 addProfile → 关页。

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:loggy/loggy.dart';
import 'package:vvvpn_client/features/profile/data/profile_data_providers.dart';
import 'package:vvvpn_client/utils/custom_loggers.dart';

class LoginPage extends HookConsumerWidget {
  const LoginPage({super.key});

  static const _loginUrl = 'https://vvvpn168.com/login';
  static const _apiBase = 'https://api.vvvpn168.com';
  // 登录成功后 web 默认跳的路径
  static final _successPathMatcher = RegExp(r'^/(dashboard|home)/?$');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
