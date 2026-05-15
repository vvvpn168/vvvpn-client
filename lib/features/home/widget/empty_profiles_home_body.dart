import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:vvvpn_client/core/localization/translations.dart';
import 'package:vvvpn_client/core/router/bottom_sheets/bottom_sheets_notifier.dart';
import 'package:vvvpn_client/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// VVVPN: 空 profile 状态主推"登录导入"—— web /login?return_to=app 流程
const _loginUrl = 'https://vvvpn168.com/login?return_to=app';

class EmptyProfilesHomeBody extends HookConsumerWidget {
  const EmptyProfilesHomeBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final theme = Theme.of(context);

    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.login_rounded, size: 48, color: theme.colorScheme.primary),
            const Gap(16),
            Text(
              "登录账号自动导入订阅",
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const Gap(8),
            Text(
              "未注册请先在浏览器访问 vvvpn168.com 创建账号",
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const Gap(20),
            ElevatedButton.icon(
              icon: const Icon(Icons.open_in_browser_rounded),
              label: const Text("登录并导入订阅"),
              onPressed: () => UriUtils.tryLaunch(Uri.parse(_loginUrl)),
            ),
            const Gap(12),
            TextButton(
              onPressed: () => ref.read(bottomSheetsNotifierProvider.notifier).showAddProfile(),
              child: Text(t.dialogs.noActiveProfile.msg, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

// class EmptyActiveProfileHomeBody extends HookConsumerWidget {
//   const EmptyActiveProfileHomeBody({super.key});

//   @override
//   Widget build(BuildContext context, WidgetRef ref) {
//     final t = ref.watch(translationsProvider).requireValue;

//     return SliverFillRemaining(
//       hasScrollBody: false,
//       child: Column(
//         mainAxisAlignment: MainAxisAlignment.center,
//         children: [
//           Text(t.home.noActiveProfileMsg),
//           const Gap(16),
//           OutlinedButton(
//             onPressed: () => const ProfilesOverviewRoute().push(context),
//             child: Text(t.profile.overviewPageTitle),
//           ),
//         ],
//       ),
//     );
//   }
// }
