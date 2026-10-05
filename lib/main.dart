import 'dart:developer' as dev;

import 'package:flutter/material.dart';

import 'state/app_store.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    // Technical details go to the developer log, never to the user.
    dev.log('Flutter error', error: details.exception, stackTrace: details.stack,
        name: 'app');
    FlutterError.presentError(details);
  };
  runApp(const Project1000App(storeLoader: AppStore.open));
}
