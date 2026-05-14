import 'package:flutter/foundation.dart';
import 'package:vvvpn_client/core/app_info/app_info_provider.dart';
import 'package:vvvpn_client/core/http_client/dio_http_client.dart';
import 'package:vvvpn_client/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'http_client_provider.g.dart';

@Riverpod(keepAlive: true)
DioHttpClient httpClient(Ref ref) {
  final client = DioHttpClient(
    timeout: const Duration(seconds: 15),
    userAgent: ref.watch(appInfoProvider).requireValue.userAgent,
    debug: kDebugMode,
  );

  ref.listen(ConfigOptions.mixedPort, (_, next) => client.setProxyPort(next), fireImmediately: true);
  return client;
}
