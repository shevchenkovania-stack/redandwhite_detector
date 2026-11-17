import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/hit_event.dart';
import 'event_repository.dart';

/// Каталог для БД и CSV-записей диагностики.
///
/// `path_provider` в стеке запрещён, поэтому берётся нативный каталог БД
/// sqflite — он приватный и доступный для записи на Android и iOS.
Future<Directory> lampDataDirectory() async => Directory(await getDatabasesPath());

/// SQLite-реализация [EventRepository].
///
/// Таблица `hit_events`: event_id TEXT PRIMARY KEY, session_id, lamp_id, color,
/// detected_at_ms INTEGER, sequence_number INTEGER, delivery_status TEXT,
/// attempts INTEGER, last_attempt_at_ms INTEGER.
class SqliteEventRepository implements EventRepository {
  SqliteEventRepository({required String fileName, String? directory})
    : _path = directory == null ? fileName : p.join(directory, fileName);

  static const String _table = 'hit_events';
  static const int _version = 1;

  static const List<String> _columns = <String>[
    'event_id',
    'session_id',
    'lamp_id',
    'color',
    'detected_at_ms',
    'sequence_number',
    'delivery_status',
    'attempts',
    'last_attempt_at_ms',
  ];

  final String _path;

  Database? _db;
  Completer<void>? _opening;

  /// Имя файла БД по умолчанию.
  static const String defaultFileName = 'lamp_events.db';

  String get databasePath => _path;

  Future<Database> _database() async {
    final Database? existing = _db;
    if (existing != null) {
      return existing;
    }
    // Защита от параллельного открытия (событие пишется из колбэка кадров,
    // очередь доставки читает его же из другого места).
    final Completer<void>? pending = _opening;
    if (pending != null) {
      await pending.future;
      return _db!;
    }
    final Completer<void> opening = Completer<void>();
    _opening = opening;
    try {
      _db = await openDatabase(
        _path,
        version: _version,
        onCreate: (Database db, int version) async {
          await db.execute('''
            CREATE TABLE $_table (
              event_id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              lamp_id TEXT NOT NULL,
              color TEXT NOT NULL,
              detected_at_ms INTEGER NOT NULL,
              sequence_number INTEGER NOT NULL,
              delivery_status TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_attempt_at_ms INTEGER
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_hit_events_session ON $_table (session_id, sequence_number)',
          );
          await db.execute(
            'CREATE INDEX idx_hit_events_status ON $_table (delivery_status)',
          );
        },
      );
      return _db!;
    } finally {
      _opening = null;
      opening.complete();
    }
  }

  @override
  Future<void> save(HitEvent event) async {
    final Database db = await _database();
    final Map<String, Object?> row = <String, Object?>{
      ...event.toMap(),
      'delivery_status': DeliveryStatus.pending.name,
      'attempts': 0,
      'last_attempt_at_ms': null,
    };
    // conflictAlgorithm.ignore: дубль eventId не создаёт вторую запись.
    await db.insert(_table, row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<List<HitEvent>> history(String sessionId) async {
    final List<StoredEvent> stored = await eventsWithStatus(sessionId);
    return stored.map((StoredEvent e) => e.event).toList();
  }

  @override
  Future<List<HitEvent>> pending() async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      columns: _columns,
      where: 'delivery_status IN (?, ?)',
      whereArgs: <Object?>[DeliveryStatus.pending.name, DeliveryStatus.failed.name],
      orderBy: 'detected_at_ms ASC, sequence_number ASC',
    );
    return rows.map((Map<String, Object?> r) => HitEvent.fromMap(r)).toList();
  }

  @override
  Future<List<StoredEvent>> eventsWithStatus(String sessionId) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      _table,
      columns: _columns,
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      orderBy: 'sequence_number ASC',
    );
    return rows.map((Map<String, Object?> r) => StoredEvent.fromMap(r)).toList();
  }

  @override
  Future<void> markSent(String eventId) async {
    final Database db = await _database();
    await db.update(
      _table,
      <String, Object?>{
        'delivery_status': DeliveryStatus.sent.name,
        'last_attempt_at_ms': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'event_id = ?',
      whereArgs: <Object?>[eventId],
    );
  }

  @override
  Future<void> markFailed(String eventId) async {
    final Database db = await _database();
    await db.rawUpdate(
      'UPDATE $_table SET delivery_status = ?, attempts = attempts + 1, last_attempt_at_ms = ? '
      'WHERE event_id = ?',
      <Object?>[DeliveryStatus.failed.name, DateTime.now().millisecondsSinceEpoch, eventId],
    );
  }

  @override
  Future<void> resetSession(String sessionId) async {
    final Database db = await _database();
    await db.delete(_table, where: 'session_id = ?', whereArgs: <Object?>[sessionId]);
  }

  @override
  Future<void> dispose() async {
    final Database? db = _db;
    _db = null;
    if (db != null) {
      await db.close();
    }
  }
}
