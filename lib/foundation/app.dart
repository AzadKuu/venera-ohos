import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/history.dart';

import 'read_later.dart';
import 'appdata.dart';
import 'favorites.dart';
import 'local.dart';
import 'log.dart';

export "widget_utils.dart";
export "context.dart";

class _App {
  String version = "1.6.0";

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isOhos => Platform.operatingSystem == 'ohos';

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS || isOhos;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  /// 鸿蒙系统 locale（由 EntryAbility 通过 venera/system_info channel 提供）。
  /// 鸿蒙 Flutter 引擎的 PlatformDispatcher.instance.locale 在某些情况下未正确
  /// 反映系统语言（返回 en），App.init() 启动时主动通过原生 channel 调
  /// i18n.System.getSystemLocale() 获取真实系统语言并缓存于此。
  Locale? _ohosSystemLocale;

  Locale get locale {
    Locale deviceLocale;
    if (isOhos && _ohosSystemLocale != null) {
      deviceLocale = _ohosSystemLocale!;
    } else {
      deviceLocale = PlatformDispatcher.instance.locale;
    }
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    if (appdata.settings['language'] != 'system') {
      return Locale(
        appdata.settings['language'].split('-')[0],
        appdata.settings['language'].split('-')[1],
      );
    }
    return deviceLocale;
  }

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  final HistoryManager history = HistoryManager();

  final LocalFavoritesManager favorites = LocalFavoritesManager();

  final LocalManager local = LocalManager();

  final ReadLaterManager readLater = ReadLaterManager();

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  Future<void> init() async {
    try {
      var packageInfo = await PackageInfo.fromPlatform();
      version = packageInfo.version;
    } catch (e, s) {
      Log.error("App.init", "Failed to read package info: $e\n$s");
    }
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
    // 确保数据/缓存目录存在，否则 sqlite3.open() 会因目录缺失返回
    // SQLITE_CANTOPEN。在 Android/桌面 path_provider 会自动建目录，
    // 但鸿蒙上不保证，需显式创建。
    Directory(dataPath).createSync(recursive: true);
    Directory(cachePath).createSync(recursive: true);
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    if (isOhos) {
      await _initOhosSystemLocale();
    }
    isInitialized = true;
  }

  /// 鸿蒙启动时通过原生 channel 获取系统 locale（BCP47，如 zh-Hans-CN），
  /// 解析后缓存到 [_ohosSystemLocale]，供 [locale] getter 优先使用。
  Future<void> _initOhosSystemLocale() async {
    try {
      const channel = MethodChannel('venera/system_info');
      final localeStr = await channel.invokeMethod<String>('getSystemLocale');
      if (localeStr == null || localeStr.isEmpty) return;
      final parsed = _parseBcp47Locale(localeStr);
      if (parsed != null) {
        _ohosSystemLocale = parsed;
        Log.info("App.init", "ohos system locale: '$localeStr' -> $parsed");
      }
    } catch (e, s) {
      Log.error("App.init", "Failed to get ohos system locale: $e\n$s");
    }
  }

  /// 解析 BCP47 locale 字符串（如 zh-Hans-CN、en-US、zh-Hant-TW）为 [Locale]。
  static Locale? _parseBcp47Locale(String s) {
    final parts = s.replaceAll('_', '-').split('-');
    if (parts.isEmpty || parts[0].isEmpty) return null;
    final language = parts[0];
    String? script;
    String? country;
    for (var i = 1; i < parts.length; i++) {
      final p = parts[i];
      if (p.length == 4) {
        script = p;
      } else if (p.length >= 2 && p.length <= 3) {
        country = p;
      }
    }
    return Locale.fromSubtags(
      languageCode: language,
      scriptCode: script,
      countryCode: country,
    );
  }

  Future<void> initComponents() async {
    await Future.wait([
      data.init(),
      history.init(),
      favorites.init(),
      local.init(),
      readLater.init(),
    ]);
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}

// ignore: non_constant_identifier_names
final App = _App();
