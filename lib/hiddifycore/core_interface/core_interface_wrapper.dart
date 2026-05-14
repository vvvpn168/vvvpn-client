import 'dart:io';

import 'package:vvvpn_client/hiddifycore/core_interface/core_interface.dart';
import 'package:vvvpn_client/hiddifycore/core_interface/core_interface_desktop.dart';
import 'package:vvvpn_client/hiddifycore/core_interface/core_interface_mobile.dart';

CoreInterface getCoreInterface() {
  if (Platform.isAndroid || Platform.isIOS) {
    return CoreInterfaceMobile();
  }
  return CoreInterfaceDesktop();
}
