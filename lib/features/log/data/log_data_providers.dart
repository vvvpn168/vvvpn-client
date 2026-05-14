import 'package:vvvpn_client/core/directories/directories_provider.dart';
import 'package:vvvpn_client/features/log/data/log_path_resolver.dart';
import 'package:vvvpn_client/features/log/data/log_repository.dart';
import 'package:vvvpn_client/hiddifycore/hiddify_core_service_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'log_data_providers.g.dart';

@Riverpod(keepAlive: true)
Future<LogRepository> logRepository(LogRepositoryRef ref) async {
  final repo = LogRepositoryImpl(
    singbox: ref.watch(hiddifyCoreServiceProvider),
    logPathResolver: ref.watch(logPathResolverProvider),
  );
  await repo.init().getOrElse((l) => throw l).run();
  return repo;
}

@Riverpod(keepAlive: true)
LogPathResolver logPathResolver(LogPathResolverRef ref) {
  return LogPathResolver(ref.watch(appDirectoriesProvider).requireValue.workingDir);
}
