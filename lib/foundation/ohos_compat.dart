import 'dart:ffi';

import 'package:sqlite3/open.dart';
import 'package:venera/foundation/app.dart';

/// HarmonyOS (ohos) 平台兼容层。
///
/// 在鸿蒙上，若某些原生 FFI 依赖缺少预编译的 `.so`，需要在此做降级处理，
/// 确保 App 能正常启动。
///
/// 当前处理：
/// - sqlite3：加载随 HAP 打包的 `libsqlite3.so`（用鸿蒙 NDK 交叉编译 arm64 版）。
///   该库放置在 `ohos/entry/src/main/libs/arm64-v8a/libsqlite3.so`。
void setupOhosCompatibility() {
  print("[venera] setupOhosCompatibility() enter, isOhos=${App.isOhos}");
  if (!App.isOhos) return;

  _setupSqlite();
}

void _setupSqlite() {
  try {
    // 加载随应用打包的 sqlite3 动态库（arm64）。
    final lib = DynamicLibrary.open('libsqlite3.so');
    // 鸿蒙在 sqlite3 包中无对应平台枚举，使用 overrideForAll 覆盖全局加载行为。
    open.overrideForAll(() => lib);
    print("[venera] sqlite3: loaded bundled libsqlite3.so");
  } catch (e) {
    print("[venera] sqlite3: failed to load bundled library: $e");
  }
}
