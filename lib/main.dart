import 'package:flutter/material.dart';
import 'package:project_1000/core/log.dart';

import 'services/cloud/account.dart';
import 'state/store_loader.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    // Technical details go to the developer log, never to the user.
    logError('Flutter error', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  try {
    // Only when built with a cloud project; otherwise nothing connects.
    await CloudConfig.initialize();
  } catch (e, s) {
    logError('Cloud setup failed', e, s);
  }
  runApp(const Project1000App(storeLoader: loadStore));
}
