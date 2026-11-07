import 'package:flutter_test/flutter_test.dart';
import 'package:openhiit/core/db/migrations/migration_9.dart';
import 'package:openhiit/core/db/tables.dart';
import 'package:openhiit/core/models/timer_type.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
      'version 8 upgrade preserves timers and initializes empty media settings',
      () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute(createTimerTableQuery.replaceAll(
        ",\n        backgrounds TEXT NOT NULL DEFAULT '{}'", ''));
    await db.execute(createIntervalTableQuery.replaceAll(
        ",\n        stage TEXT NOT NULL DEFAULT ''", ''));
    final oldTimer = TimerType.empty()..id = 'existing';
    final map = oldTimer.toMap()..remove('backgrounds');
    await db.insert(timerTableName, map);
    await migration9(db);
    final rows = await db.query(timerTableName);
    expect(rows, hasLength(1));
    expect(TimerType.fromMap(rows.single).id, 'existing');
    expect(TimerType.fromMap(rows.single).backgrounds, isEmpty);
    await db.update(
        timerTableName, {'backgrounds': '{"work":"local:images/test.png"}'});
    final updated = TimerType.fromMap((await db.query(timerTableName)).single);
    expect(updated.backgrounds['work'], 'local:images/test.png');
    final columns = await db.rawQuery('PRAGMA table_info($intervalTableName)');
    expect(columns.any((row) => row['name'] == 'stage'), isTrue);
  });
}
