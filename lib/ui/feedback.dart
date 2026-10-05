import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:project_1000/core/log.dart';

import '../data/archive_repository.dart';
import '../data/models.dart';

/// Turns an error into a message a normal person can act on.
String friendlyError(Object error) {
  if (error is ListFullException) {
    return 'Your list already has $maxItems things. '
        'Delete one to make room for another.';
  }
  if (isOutOfSpace(error)) {
    return 'Your phone is out of storage space. Free up some space and try '
        'again. Nothing was lost.';
  }
  if (error is ItemNotFoundException) {
    return 'That entry no longer exists.';
  }
  if (error is FileSystemException) {
    return 'A file couldn\'t be read or saved. Nothing was lost; please try '
        'again.';
  }
  return 'Something went wrong and the change wasn\'t saved. '
      'Your existing list is safe.';
}

bool isOutOfSpace(Object error) {
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    // ENOSPC on Android/iOS, ERROR_DISK_FULL / HANDLE_DISK_FULL on Windows.
    return code == 28 || code == 112 || code == 39;
  }
  if (error is DatabaseException) {
    final m = error.toString().toLowerCase();
    return m.contains('sqlite_full') || m.contains('disk is full');
  }
  return false;
}

/// Logs [error] for developers and shows a friendly snackbar.
void showError(BuildContext context, Object error, [StackTrace? stack]) {
  logError('Operation failed', error, stack);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(friendlyError(error))));
}

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Runs [action], reporting failures. Returns true on success.
Future<bool> guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    return true;
  } catch (e, s) {
    if (context.mounted) showError(context, e, s);
    return false;
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
