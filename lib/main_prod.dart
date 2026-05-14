import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vvvpn_client/bootstrap.dart';
import 'package:vvvpn_client/core/model/environment.dart';

Future<void> main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
  );

  return await lazyBootstrap(widgetsBinding, Environment.prod);
}
