import 'package:flutter/material.dart';
import 'package:project_1000/core/log.dart';

import 'state/app_store.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    // Technical details go to the developer log, never to the user.
    logError('Flutter error', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  runApp(const Project1000App(storeLoader: AppStore.open));
}
