import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';

/// 鸿蒙"智感握姿"（智能感知握持姿势）Flutter 侧封装。
///
/// 与 EntryAbility 的 venera/smart_grip channel 对接：鸿蒙侧通过
/// `@ohos.multimodalAwareness.motion` 监听 `holdingHandChanged`
/// （握持手变化），把"左手握/右手握/双手握/未握持"推送到 Dart 侧。
///
/// 用途：大屏（折叠屏/平板）状态下，最外层界面（主页/搜索等）默认在
/// 左侧；检测到右手握持时自动切到右侧，方便单手操作。
///
/// 只在鸿蒙（App.isOhos）生效，其他平台所有方法均为 no-op。
class SmartGrip {
  static const MethodChannel _channel = MethodChannel('venera/smart_grip');

  static bool _handlerRegistered = false;

  /// 大屏时侧边栏是否显示在右侧（右手握持时切换为 true）。
  /// 非鸿蒙平台恒为 false。UI 侧监听此值触发重建。
  static final ValueNotifier<bool> sidebarOnRight = ValueNotifier(false);

  /// 注册鸿蒙侧握持状态推送处理器（应在 App 启动早期调用一次，幂等）。
  static void init() {
    if (!App.isOhos || _handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'holdingHandChanged') {
        final hand = call.arguments as String?;
        Log.info("SmartGrip", "holdingHandChanged: $hand");
        // 只有明确为单手（left/right）才切换方向；双手/未握持/未知
        // 保持当前方向，避免用户调整握姿时界面来回抖动。
        if (hand == 'right') {
          sidebarOnRight.value = true;
        } else if (hand == 'left') {
          sidebarOnRight.value = false;
        }
      }
      return null;
    });
  }
}
