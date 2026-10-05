import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';

/// Records a technical error for developers: in the debugger log and, in
/// release builds too, one line in the system log (`adb logcat`). Never
/// shown to the user, and never sent anywhere.
void logError(String what, Object error, [StackTrace? stack]) {
  dev.log(what, error: error, stackTrace: stack, name: 'project-1000');
  debugPrint('[project-1000] $what: $error');
}
