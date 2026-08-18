import 'package:flutter/services.dart';
import 'package:venera/foundation/log.dart';

/// 鸿蒙 AI 超分辨率能力封装。
///
/// 通过 MethodChannel 调用鸿蒙侧 @kit.CoreVisionKit 的 ImageSuperResolution
/// 端侧 AI 能力（EntryAbility 中注册）。仅在鸿蒙设备上可用；其它平台
/// invokeMethod 会抛 MissingPluginException，[isAvailable] 返回 false，
/// 调用方应自动降级为原图。
class AiSuperResolution {
  AiSuperResolution._();

  static const _channel = MethodChannel('venera/ai_super_resolution');

  static bool? _available;

  /// 鸿蒙侧是否注册了 AI 超分 channel（缓存探测结果）。
  static Future<bool> get isAvailable async {
    if (_available != null) return _available!;
    try {
      await _channel.invokeMethod<void>('ping');
      _available = true;
    } catch (e) {
      _available = false;
    }
    Log.info("AiSuperResolution", "isAvailable = $_available");
    return _available!;
  }

  /// 对图片字节做 AI 超分增强。
  ///
  /// 返回增强后的 JPEG 字节；任何失败（channel 缺失、超分异常、超时）
  /// 都返回 null，调用方应降级使用原图。
  static Future<Uint8List?> superResolve(Uint8List data) async {
    try {
      final result = await _channel
          .invokeMethod<Uint8List>('superResolve', {'data': data})
          .timeout(const Duration(seconds: 30));
      return result;
    } catch (e) {
      Log.warning("AiSuperResolution", "superResolve failed: $e");
      return null;
    }
  }
}
