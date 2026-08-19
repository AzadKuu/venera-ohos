import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/log.dart';

/// 鸿蒙 AI 超分辨率能力封装。
///
/// 通过 MethodChannel 调用鸿蒙侧 @kit.CoreVisionKit 的 ImageSuperResolution
/// 端侧 AI 能力（EntryAbility 中注册）。仅在鸿蒙设备上可用；其它平台
/// invokeMethod 会抛 MissingPluginException，[isAvailable] 返回 false，
/// 调用方应自动降级为原图。
///
/// 通道设计：
/// - `venera/ai_super_resolution`（MethodChannel）：仅用于 [isAvailable] 的
///   `ping` 探测，启动时调一次，低频，序列化开销可忽略。
/// - `venera/ai_super_resolution_bin`（BasicMessageChannel + BinaryCodec）：
///   [superResolve] 热路径走二进制通道，直接传 ByteBuffer，零序列化、
///   零拷贝，避免 MethodChannel 对大图片字节的 JSON 编码开销。
class AiSuperResolution {
  AiSuperResolution._();

  /// 探测通道（低频，仅 ping）。
  static const _channel = MethodChannel('venera/ai_super_resolution');

  /// 超分热路径二进制通道（零序列化传 ByteBuffer）。
  static const _binChannel = BasicMessageChannel<ByteData>(
    'venera/ai_super_resolution_bin',
    BinaryCodec(),
  );

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
  ///
  /// 走 [BasicMessageChannel]+[BinaryCodec]：[ByteData.sublistView] 对
  /// [data] 做零拷贝视图，鸿蒙侧用 BinaryCodec.INSTANCE_DIRECT 直接复用
  /// 同一 ArrayBuffer，省掉 MethodChannel 的序列化与中间拷贝。
  static Future<Uint8List?> superResolve(Uint8List data) async {
    try {
      final byteData = ByteData.sublistView(data);
      final result = await _binChannel
          .send(byteData)
          .timeout(const Duration(seconds: 30));
      if (result == null) return null;
      return result.buffer.asUint8List(
        result.offsetInBytes,
        result.lengthInBytes,
      );
    } catch (e) {
      Log.warning("AiSuperResolution", "superResolve failed: $e");
      return null;
    }
  }
}
