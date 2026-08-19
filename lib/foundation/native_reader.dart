import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';

/// 鸿蒙原生阅读器（ArkTS + @ohos/imageknifepro + AI 超分）Dart 侧封装。
///
/// 通过 venera/native_reader MethodChannel 通知鸿蒙侧打开 NativeReader.ets 页面。
/// 仅在鸿蒙平台可用；其他平台 [isAvailable] 返回 false。
///
/// 设计：Flutter 侧负责收集图片路径列表（LocalManager.getImages），
/// 通过 channel 传递给鸿蒙侧，鸿蒙侧用 ImageKnifeComponent 显示图片，
/// AI 超分在 ArkTS 侧直接执行（AiSuperResolutionHelper），不经过 Flutter。
class NativeReader {
  static const _channel = MethodChannel('venera/native_reader');

  /// 是否可用：鸿蒙平台且设置开关开启。
  static bool get isAvailable =>
      App.isOhos && appdata.settings['useNativeReaderForLocal'] == true;

  /// 打开原生阅读器。
  ///
  /// [images] 图片路径列表（file:// 格式或绝对路径）。
  /// [initialPage] 初始页码（0-based）。
  /// [title] 漫画标题（显示在顶部栏）。
  /// [enableAiSuperResolution] 是否启用 AI 超分。
  ///
  /// 返回 true 表示成功打开，false 表示失败或平台不支持。
  static Future<bool> open({
    required List<String> images,
    int initialPage = 0,
    String title = '',
    bool enableAiSuperResolution = false,
  }) async {
    if (!App.isOhos) {
      Log.warning("NativeReader", "not available on this platform");
      return false;
    }
    if (images.isEmpty) {
      Log.warning("NativeReader", "no images to show");
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('open', {
        'images': images,
        'initialPage': initialPage,
        'title': title,
        'enableAiSuperResolution': enableAiSuperResolution,
      });
      Log.info("NativeReader", "open result: $result");
      return result ?? false;
    } catch (e) {
      Log.error("NativeReader", "open failed: $e");
      return false;
    }
  }
}
