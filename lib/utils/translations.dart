import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import '../foundation/app.dart';

extension AppTranslation on String {
  String _translate() {
    var locale = App.locale;
    var key = "${locale.languageCode}_${locale.countryCode}";
    if (locale.languageCode == "en") {
      key = "en_US";
    }
    return (translations[key]?[this]) ?? this;
  }

  String get tl => _translate();

  String get tlEN => translations["en_US"]![this] ?? this;

  String tlParams(Map<String, Object> values) {
    var res = _translate();
    for (var entry in values.entries) {
      res = res.replaceFirst("@${entry.key}", entry.value.toString());
    }
    return res;
  }

  // 默认为空 map，避免 init() 失败时 .tl 访问抛 LateInitializationError
  static Map<String, Map<String, String>> translations = {};

  static Future<void> init() async {
    try {
      var data = await rootBundle.load("assets/translation.json");
      // 必须使用 offsetInBytes/lengthInBytes 切出有效数据区，
      // 否则鸿蒙上 ByteData.offsetInBytes 非零时会读到错误数据导致 jsonDecode 失败。
      var bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      var json = jsonDecode(utf8.decode(bytes));
      translations = {
        for (var e in json.entries) e.key: Map<String, String>.from(e.value),
      };
      print(
        "[venera] AppTranslation.init() loaded ${translations.length} locales",
      );
    } catch (e, s) {
      // 不要静默失败：打印原因，并保留空 translations 兜底，避免 UI 崩溃
      print("[venera] AppTranslation.init() failed: $e\n$s");
    }
  }

  /// Translate a string using specified comic source
  String ts(String sourceKey) {
    var comicSource = ComicSource.find(sourceKey);
    if (comicSource == null || comicSource.translations == null) {
      return this;
    }
    var locale = App.locale;
    var lc = locale.languageCode;
    var cc = locale.countryCode;
    var key = "$lc${cc == null ? "" : "_$cc"}";
    return (comicSource.translations![key] ??
            comicSource.translations![lc])?[this] ??
        this;
  }
}

extension ListTranslation on List<String> {
  List<String> _translate() {
    return List.generate(length, (index) => this[index].tl);
  }

  List<String> get tl => _translate();
}
