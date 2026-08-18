import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

Database openSqliteDatabase(String path) {
  print("[venera] openSqliteDatabase: path=$path");
  // 鸿蒙：sqlite3 包的 _defaultOpen 现在已识别 ohos（本地副本已改），
  // 这里仍显式 override 作为双保险，确保后台 isolate 也能加载打包的
  // libsqlite3.so（overrideForAll 只在当前 isolate 内生效）。
  if (Platform.operatingSystem == 'ohos') {
    try {
      open.overrideForAll(() => DynamicLibrary.open('libsqlite3.so'));
    } catch (e) {
      print("[venera] openSqliteDatabase: ohos override failed: $e");
    }
  }
  // 确保数据库文件所在目录存在，否则 sqlite3.open() 返回 SQLITE_CANTOPEN。
  // 鸿蒙上 path_provider 不保证自动创建应用数据目录。
  File(path).parent.createSync(recursive: true);
  final db = sqlite3.open(path);
  print("[venera] openSqliteDatabase: sqlite3.open done");
  db.execute('PRAGMA journal_mode = DELETE;');
  db.execute('PRAGMA synchronous = NORMAL;');
  db.execute('PRAGMA busy_timeout = 5000;');
  print("[venera] openSqliteDatabase: pragma done");
  return db;
}

/// Execute a function with a temporary database connection, ensuring cleanup.
/// Use this in Isolate operations to avoid manual open/dispose boilerplate.
Future<T> withDatabase<T>(
  String path,
  Future<T> Function(Database db) fn,
) async {
  final db = openSqliteDatabase(path);
  try {
    return await fn(db);
  } finally {
    db.dispose();
  }
}
