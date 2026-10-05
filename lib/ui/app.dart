import 'dart:developer' as dev;

import 'package:flutter/material.dart';

import '../state/app_store.dart';
import 'screens/home_screen.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final store = await widget.storeLoader();
      setState(() => _store = store);
    } catch (e, s) {
      dev.log('Could not open archive', error: e, stackTrace: s, name: 'app');
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    Widget app(ThemeMode mode, Widget home) => MaterialApp(
          title: appName,
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: mode,
          // Every route (not just home) can reach the store.
          builder: store == null
              ? null
              : (context, child) => StoreScope(store: store, child: child!),
          home: home,
        );

    if (store == null) {
      return app(
          ThemeMode.system,
          _error != null
              ? _StartupError(onRetry: _load)
              : const _Loading());
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
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: Emblem(size: 96)),
      );
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.onRetry});

  final VoidCallback onRetry;

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
              Text('Your list couldn\'t be opened',
                  style: display(22), textAlign: TextAlign.center),
              const SizedBox(height: 12),
              const Text(
                'Nothing has been deleted. This can happen if the phone is '
                'out of storage space. Free up some space and try again.',
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
