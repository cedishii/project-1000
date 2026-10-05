import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Current database schema version. Increase it and add a step to
/// [_migrations] whenever the schema changes; never edit an old step.
const int schemaVersion = 2;

/// Opens (creating if needed) the archive database at [path].
Future<Database> openArchiveDatabase(String path, {DatabaseFactory? factory}) {
  final f = factory ?? databaseFactory;
  return f.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: schemaVersion,
      // Creating and upgrading run in one transaction with foreign keys
      // still off, so a table can be rebuilt (SQLite's documented way to
      // change constraints) without cascading deletes. If anything fails
      // the transaction rolls back and the old database is untouched.
      onCreate: (db, version) => _migrate(db, 0, version),
      onUpgrade: _migrate,
      onOpen: (db) async {
        // Enforce relationships (memory → item, photo → memory, …).
        await db.execute('PRAGMA foreign_keys = ON');
      },
    ),
  );
}

Future<void> _migrate(Database db, int from, int to) async {
  final batch = db.batch();
  for (final step in _migrations.skip(from).take(to - from)) {
    step(batch);
  }
  await batch.commit(noResult: true);
  // Refuse to finish a migration that broke a relationship.
  final broken = await db.rawQuery('PRAGMA foreign_key_check');
  if (broken.isNotEmpty) {
    throw StateError('Migration $from → $to broke references: $broken');
  }
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
  // 1 → 2: journeys and the profile. Every existing item becomes part
  // of Journey 1; item numbers are unique per journey instead of overall.
  (b) {
    final now = DateTime.now().toUtc().toIso8601String();
    final journeyId = const Uuid().v4();
    b.execute('''
      CREATE TABLE journeys (
        id           TEXT PRIMARY KEY,
        number       INTEGER NOT NULL UNIQUE CHECK (number >= 1),
        status       TEXT NOT NULL CHECK (status IN ('active', 'archived')),
        started_on   TEXT,
        completed_on TEXT,
        snapshot     TEXT,
        created_at   TEXT NOT NULL,
        archived_at  TEXT
      )''');
    // At most one journey is active.
    b.execute(
      "CREATE UNIQUE INDEX journeys_one_active ON journeys(status) "
      "WHERE status = 'active'",
    );
    b.insert('journeys', {
      'id': journeyId,
      'number': 1,
      'status': 'active',
      'created_at': now,
    });
    b.execute('''
      CREATE TABLE items_v2 (
        id           TEXT PRIMARY KEY,
        journey_id   TEXT NOT NULL REFERENCES journeys(id),
        number       INTEGER NOT NULL CHECK (number BETWEEN 1 AND 1000),
        position     INTEGER NOT NULL,
        title        TEXT NOT NULL,
        description  TEXT NOT NULL DEFAULT '',
        is_completed INTEGER NOT NULL DEFAULT 0,
        completed_on TEXT,
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL,
        UNIQUE (journey_id, number)
      )''');
    b.rawInsert(
      '''
      INSERT INTO items_v2 (id, journey_id, number, position, title,
          description, is_completed, completed_on, created_at, updated_at)
        SELECT id, ?, number, position, title, description, is_completed,
               completed_on, created_at, updated_at
        FROM items ORDER BY rowid''',
      [journeyId],
    );
    b.execute('DROP TABLE items');
    b.execute('ALTER TABLE items_v2 RENAME TO items');
    b.execute(
      'CREATE INDEX items_journey_position ON items(journey_id, position)',
    );
    b.execute('''
      CREATE TABLE profile (
        id         INTEGER PRIMARY KEY CHECK (id = 1),
        name       TEXT NOT NULL DEFAULT '',
        nickname   TEXT NOT NULL DEFAULT '',
        age        INTEGER,
        started_on TEXT,
        bio        TEXT NOT NULL DEFAULT '',
        photo      TEXT,
        updated_at TEXT NOT NULL
      )''');
  },
];
