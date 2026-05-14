import 'package:fpdart/fpdart.dart';
import 'package:vvvpn_client/core/utils/exception_handler.dart';
import 'package:vvvpn_client/features/stats/model/stats_failure.dart';
import 'package:vvvpn_client/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:vvvpn_client/hiddifycore/hiddify_core_service.dart';
import 'package:vvvpn_client/utils/custom_loggers.dart';

abstract interface class StatsRepository {
  Stream<Either<StatsFailure, SystemInfo>> watchStats();
}

class StatsRepositoryImpl with ExceptionHandler, InfraLogger implements StatsRepository {
  StatsRepositoryImpl({required this.singbox});

  final HiddifyCoreService singbox;

  @override
  Stream<Either<StatsFailure, SystemInfo>> watchStats() {
    return singbox.watchStats().handleExceptions(StatsUnexpectedFailure.new);
  }
}
