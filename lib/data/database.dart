import 'package:sqflite/sqflite.dart';

/// Current database schema version. Increase it and add a step to
/// [_migrations] whenever the schema changes; never edit an old step.
const int schemaVersion = 1;

/// Opens (creating if needed) the archive database at [path].
Future<Database> openArchiveDatabase(String path,
    {DatabaseFactory? factory}) {
  final f = factory ?? databaseFactory;
  return f.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: schemaVersion,
      onConfigure: (db) async {
        // Enforce relationships (memory → item, photo → memory).
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        final batch = db.batch();
        for (final step in _migrations.take(version)) {
          step(batch);
        }
        await batch.commit(noResult: true);
      },
      onUpgrade: (db, from, to) async {
        final batch = db.batch();
        for (final step in _migrations.skip(from).take(to - from)) {
          step(batch);
        }
        await batch.commit(noResult: true);
      },
    ),
  );
}

/// `_migrations[n]` upgrades schema n → n+1.
final List<void Function(Batch)> _migrations = [
  // 0 → 1: initial schema.
  (b) {
    b.execute('''
      CREATE TABLE items (
        id           TEXT PRIMARY KEY,
        number       INTEGER NOT NULL UNIQUE CHECK (number BETWEEN 1 AND 1000),
        position     INTEGER NOT NULL,
        title        TEXT NOT NULL,
        description  TEXT NOT NULL DEFAULT '',
        is_completed INTEGER NOT NULL DEFAULT 0,
        completed_on TEXT,
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL
      )''');
    b.execute('CREATE INDEX items_position ON items(position)');
    b.execute('''
      CREATE TABLE memories (
        id         TEXT PRIMARY KEY,
        item_id    TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        position   INTEGER NOT NULL,
        title      TEXT NOT NULL DEFAULT '',
        body       TEXT NOT NULL DEFAULT '',
        date       TEXT NOT NULL,
        location   TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )''');
    b.execute('CREATE INDEX memories_item ON memories(item_id, position)');
    b.execute('''
      CREATE TABLE memory_tags (
        memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        position  INTEGER NOT NULL,
        tag       TEXT NOT NULL,
        PRIMARY KEY (memory_id, tag)
      )''');
    b.execute('CREATE INDEX memory_tags_tag ON memory_tags(tag)');
    b.execute('''
      CREATE TABLE photos (
        id         TEXT PRIMARY KEY,
        memory_id  TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
        position   INTEGER NOT NULL,
        file       TEXT NOT NULL,
        thumb      TEXT NOT NULL,
        width      INTEGER,
        height     INTEGER,
        created_at TEXT NOT NULL
      )''');
    b.execute('CREATE INDEX photos_memory ON photos(memory_id, position)');
    b.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )''');
  },
];
