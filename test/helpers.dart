import 'dart:io';

import 'package:project_1000/state/app_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A throwaway app-documents folder and a way to "restart the app"
/// (close and reopen the store on the same folder).
class TestArchive {
  TestArchive._(this.root);

  static Future<TestArchive> create() async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('p1000_test_');
    return TestArchive._(root);
  }

  final Directory root;
  AppStore? _store;

  Future<AppStore> open() async =>
      _store = await AppStore.open(root: root, factory: databaseFactoryFfi);

  Future<AppStore> restart() async {
    await _store?.close();
    return open();
  }

  Future<void> dispose() async {
    await _store?.close();
    await root.delete(recursive: true);
  }
}

List<int> numbersOf(AppStore s) => s.items.map((i) => i.number).toList();
List<String> titlesOf(AppStore s) => s.items.map((i) => i.title).toList();
