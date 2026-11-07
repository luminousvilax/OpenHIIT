import 'package:openhiit/core/db/tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> migration9(Database db) async {
  await db.execute(
      "ALTER TABLE $timerTableName ADD COLUMN backgrounds TEXT NOT NULL DEFAULT '{}'");
  await db.execute(
      "ALTER TABLE $intervalTableName ADD COLUMN stage TEXT NOT NULL DEFAULT ''");
}
