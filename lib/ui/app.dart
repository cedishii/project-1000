import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent;
import 'package:project_1000/core/log.dart';

import '../data/archive_backend.dart';
import '../services/cloud/account.dart';
import '../state/app_store.dart';
import '../state/store_loader.dart';
import 'layout.dart';
import 'screens/account_screen.dart' show showChangePassword;
import 'screens/home_screen.dart';
import 'screens/sign_in_screen.dart';
import 'store_scope.dart';
import 'theme.dart';
import 'widgets/emblem.dart';

const appName = 'Project: 1000';
const appTagline = '1000 Things Before I Die';

class Project1000App extends StatefulWidget {
  const Project1000App({super.key, required this.storeLoader});

  final Future<AppStore> Function() storeLoader;

  @override
  State<Project1000App> createState() => _Project1000AppState();
}

class _Project1000AppState extends State<Project1000App> {
  AppStore? _store;
  Object? _error;
  SignInRequired? _signIn;
  /// A new navigator for every state (loading, sign-in, each opened
  /// archive), so no screen of a previous state survives.
  var _navigator = GlobalKey<NavigatorState>();
  StreamSubscription<Object?>? _auth;

  @override
  void initState() {
    super.initState();
    _load();
    if (CloudConfig.isReady) {
      // A password-reset link signs the user in; ask for the new password.
      _auth = Account(CloudConfig.client).changes.listen((state) {
        if (state.event == AuthChangeEvent.passwordRecovery) {
          _askForNewPassword();
        }
      });
    }
  }

  @override
  void dispose() {
    _auth?.cancel();
    super.dispose();
  }

  Future<void> _askForNewPassword() async {
    await _load();
    for (var i = 0; i < 50; i++) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        await showChangePassword(context, title: 'Choose a new password');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Opens the archive again: after signing in or out, or switching
  /// which archive this phone uses.
  Future<void> _load() async {
    final old = _store;
    setState(() {
      _error = null;
      _signIn = null;
      _store = null;
    });
    await old?.close();
    try {
      final store = await widget.storeLoader();
      setState(() {
        _navigator = GlobalKey();
        _store = store;
      });
    } on SignInRequired catch (e) {
      setState(() {
        _navigator = GlobalKey();
        _signIn = e;
      });
    } catch (e, s) {
      logError('Could not open archive', e, s);
      setState(() {
        _navigator = GlobalKey();
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    Widget app(ThemeMode mode, Widget home) => MaterialApp(
      key: ObjectKey(_navigator),
      navigatorKey: _navigator,
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      // Every route (not just home) can reach the store and restart the
      // app; on wide screens content keeps a readable width.
      builder: (context, child) => AppRestart(
        restart: _load,
        child: AdaptiveFrame(
          child: store == null
              ? child!
              : StoreScope(store: store, child: child!),
        ),
      ),
      home: home,
    );

    if (store == null) {
      final signIn = _signIn;
      return app(
        ThemeMode.system,
        signIn != null
            ? SignInScreen(membership: signIn.membership, onDone: _load)
            : _error != null
            ? _StartupError(onRetry: _load, error: _error!)
            : const _Loading(),
      );
    }
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => app(store.themeMode, const HomeScreen()),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Emblem(size: 96)));
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.onRetry, required this.error});

  final VoidCallback onRetry;
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Emblem(size: 88),
              const SizedBox(height: 24),
              Text(
                'Your list couldn\'t be opened',
                style: display(22),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                error is CloudUnavailableException
                    ? "Your account couldn't be reached. Check your internet "
                          'connection and try again. Nothing has been deleted.'
                    : 'Nothing has been deleted. This can happen if the phone '
                          'is out of storage space. Free up some space and try '
                          'again.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets any screen reopen the archive (after signing in or out, or
/// switching which archive this phone uses).
class AppRestart extends InheritedWidget {
  const AppRestart({super.key, required this.restart, required super.child});

  final Future<void> Function() restart;

  static Future<void> of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppRestart>()!.restart();

  @override
  bool updateShouldNotify(AppRestart oldWidget) => false;
}
