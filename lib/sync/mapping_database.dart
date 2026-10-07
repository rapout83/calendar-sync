import 'package:sqflite/sqflite.dart';
import 'database_provider.dart';

class MappingDatabase {
  static const _tableName = 'sync_mappings';
  static const _columnId = 'id';
  static const _columnProfileId = 'profile_id';
  static const _columnSourceCalendarId = 'source_calendar_id';
  static const _columnSourceEventId = 'source_event_id';
  static const _columnTargetCalendarId = 'target_calendar_id';
  static const _columnTargetEventId = 'target_event_id';
  static const _columnSyncedAt = 'synced_at';
  static const _columnCanonicalTime = 'canonical_time';
  static const _columnSourceSignature = 'source_signature';

  static const _statusTable = 'sync_status';
  static const _statusId = 'id';
  static const _statusProfileId = 'profile_id';
  static const _statusTimestamp = 'timestamp';
  static const _statusSynced = 'synced';
  static const _statusDeleted = 'deleted';
  static const _statusSkipped = 'skipped';
  static const _statusErrors = 'errors';
  static const _statusUpdated = 'updated';

  static const _createdEventsTable = 'sync_created_events';
  static const _ceCalendarId = 'calendar_id';
  static const _ceEventId = 'event_id';

  final DatabaseProvider _dbProvider;

  MappingDatabase() : _dbProvider = DatabaseProvider();

  Future<Database> get database => _dbProvider.database;

  Future<bool> isEventSynced(
    String profileId,
    String sourceCalendarId,
    String sourceEventId,
  ) async {
    final db = await database;
    final result = await db.query(
      _tableName,
      where:
          '$_columnProfileId = ? AND $_columnSourceCalendarId = ? AND $_columnSourceEventId = ?',
      whereArgs: [profileId, sourceCalendarId, sourceEventId],
      limit: 1,
    );
    final synced = result.isNotEmpty;
    return synced;
  }

  Future<void> insertMapping({
    required String profileId,
    required String sourceCalendarId,
    required String sourceEventId,
    required String targetCalendarId,
    required String targetEventId,
    required String syncedAt,
    String? canonicalTime,
  }) async {
    final db = await database;
    await db.insert(
      _tableName,
      {
        _columnProfileId: profileId,
        _columnSourceCalendarId: sourceCalendarId,
        _columnSourceEventId: sourceEventId,
        _columnTargetCalendarId: targetCalendarId,
        _columnTargetEventId: targetEventId,
        _columnSyncedAt: syncedAt,
        if (canonicalTime != null) _columnCanonicalTime: canonicalTime,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Remembers the [sourceSignature] the target was last written from.
  Future<void> recordSourceSignature(
    String profileId,
    String sourceCalendarId,
    String sourceEventId,
    String signature,
  ) async {
    final db = await database;
    await db.update(
      _tableName,
      {_columnSourceSignature: signature},
      where:
          '$_columnProfileId = ? AND $_columnSourceCalendarId = ? AND $_columnSourceEventId = ?',
      whereArgs: [profileId, sourceCalendarId, sourceEventId],
    );
  }

  Future<List<Map<String, Object?>>> listMappingsForCalendar(
    String profileId,
    String sourceCalendarId,
  ) async {
    final db = await database;
    final result = await db.query(
      _tableName,
      where:
          '$_columnProfileId = ? AND $_columnSourceCalendarId = ?',
      whereArgs: [profileId, sourceCalendarId],
    );
    return result;
  }

  Future<void> deleteMapping(int id) async {
    final db = await database;
    await db.delete(
      _tableName,
      where: '$_columnId = ?',
      whereArgs: [id],
    );
  }

  Future<void> insertStatus({
    required String profileId,
    required String timestamp,
    required int synced,
    required int deleted,
    required int skipped,
    required int updated,
    required int errors,
  }) async {
    final db = await database;
    await db.insert(_statusTable, {
      _statusProfileId: profileId,
      _statusTimestamp: timestamp,
      _statusSynced: synced,
      _statusDeleted: deleted,
      _statusSkipped: skipped,
      _statusUpdated: updated,
      _statusErrors: errors,
    });
    final count = (await db.rawQuery(
            'SELECT COUNT(*) AS cnt FROM $_statusTable WHERE $_statusProfileId = ?',
            [profileId]))
        .first['cnt'] as int;
    if (count > 20) {
      final oldest = await db.query(
        _statusTable,
        columns: [_statusId],
        where: '$_statusProfileId = ?',
        whereArgs: [profileId],
        orderBy: '$_statusId ASC',
        limit: count - 20,
      );
      for (final row in oldest) {
        await db.delete(
          _statusTable,
          where: '$_statusId = ?',
          whereArgs: [row[_statusId]],
        );
      }
    }
  }

  Future<List<Map<String, Object?>>> getStatusHistory({
    int limit = 20,
    String? profileId,
  }) async {
    final db = await database;
    if (profileId != null) {
      return db.query(
        _statusTable,
        where: '$_statusProfileId = ?',
        whereArgs: [profileId],
        orderBy: '$_statusId DESC',
        limit: limit,
      );
    }
    return db.query(
      _statusTable,
      orderBy: '$_statusId DESC',
      limit: limit,
    );
  }

  Future<bool> isEventCreatedBySync(
    String calendarId,
    String eventId,
  ) async {
    final db = await database;
    final result = await db.query(
      _createdEventsTable,
      where: '$_ceCalendarId = ? AND $_ceEventId = ?',
      whereArgs: [calendarId, eventId],
      limit: 1,
    );
    final created = result.isNotEmpty;
    return created;
  }

  Future<void> insertCreatedEvent(
    String calendarId,
    String eventId,
  ) async {
    final db = await database;
    await db.insert(
      _createdEventsTable,
      {
        _ceCalendarId: calendarId,
        _ceEventId: eventId,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> deleteCreatedEvent(
    String calendarId,
    String eventId,
  ) async {
    final db = await database;
    await db.delete(
      _createdEventsTable,
      where: '$_ceCalendarId = ? AND $_ceEventId = ?',
      whereArgs: [calendarId, eventId],
    );
  }

  static const _lockTable = 'sync_lock';
  static const _logTable = 'sync_log';
  static const _maxLogRows = 1000;

  /// Takes the single cross-isolate sync lock for [owner].
  ///
  /// Background jobs and the UI run syncs in separate isolates with their
  /// own database connections, so the lock lives in the shared database.
  /// A lock older than [staleAfter] is assumed to belong to a sync that was
  /// killed and is taken over.
  Future<bool> tryAcquireSyncLock(
    String owner, {
    Duration staleAfter = const Duration(minutes: 10),
  }) async {
    final db = await database;
    final now = DateTime.now().toUtc();
    final staleBefore = now.subtract(staleAfter).toIso8601String();

    // Check with a plain read first so waiting syncs don't compete with the
    // running one for the write lock.
    final current = await db.query(_lockTable);
    if (current.isNotEmpty &&
        current.first['owner'] != owner &&
        (current.first['acquired_at'] as String).compareTo(staleBefore) >= 0) {
      return false;
    }

    return db.transaction((txn) async {
      await txn.delete(
        _lockTable,
        where: 'acquired_at < ?',
        whereArgs: [staleBefore],
      );
      await txn.insert(
        _lockTable,
        {'id': 1, 'owner': owner, 'acquired_at': now.toIso8601String()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final rows = await txn.query(_lockTable, columns: ['owner']);
      return rows.isNotEmpty && rows.first['owner'] == owner;
    });
  }

  Future<void> releaseSyncLock(String owner) async {
    final db = await database;
    await db.delete(_lockTable, where: 'owner = ?', whereArgs: [owner]);
  }

  Future<void> appendSyncLog(String profileId, String message) async {
    final db = await database;
    final id = await db.insert(_logTable, {
      'timestamp': DateTime.now().toIso8601String(),
      'profile_id': profileId,
      'message': message,
    });
    if (id % 50 == 0) {
      await db.delete(
        _logTable,
        where: 'id <= ?',
        whereArgs: [id - _maxLogRows],
      );
    }
  }

  Future<List<Map<String, Object?>>> getSyncLog({int limit = _maxLogRows}) async {
    final db = await database;
    return db.query(_logTable, orderBy: 'id DESC', limit: limit);
  }

  Future<void> clearSyncLog() async {
    final db = await database;
    await db.delete(_logTable);
  }

  Future<List<Map<String, Object?>>> listMappingsForProfile(
    String profileId,
  ) async {
    final db = await database;
    return db.query(
      _tableName,
      where: '$_columnProfileId = ?',
      whereArgs: [profileId],
    );
  }
}
