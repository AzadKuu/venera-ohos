import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

/// 鸿蒙"应用接续"（跨设备流转）Flutter 侧封装。
///
/// 与 EntryAbility 的 venera/continuation channel 对接，实现把"正在阅读的
/// 漫画 + 章节 + 页码"从源设备流转到目标设备继续阅读：
///
/// - 源设备：阅读器在翻页/切章时调用 [reportReaderState] 主动上报阅读位置，
///   鸿蒙侧缓存到 continueState；系统触发流转时 onContinue 直接读取返回。
/// - 目标设备（冷启动）：App 启动后调用 [checkPendingContinuation] 主动拉取
///   待恢复状态并跳转；目标设备（热启动）：鸿蒙侧通过 restorePending 主动
///   推送，本模块的 handler 收到后同样跳转。
///
/// 只在鸿蒙（App.isOhos）生效，其他平台所有方法均为 no-op。
class Continuation {
  static const MethodChannel _channel = MethodChannel('venera/continuation');

  static bool _handlerRegistered = false;

  /// 当前是否正在阅读器页面（进入/退出时由 Reader 通知鸿蒙侧）。
  ///
  /// 鸿蒙侧 onContinue 据此决定是否允许流转：只有阅读器激活且有阅读状态
  /// 时才 AGREE，避免在主页等不支持接续的页面误显示接续入口。
  static bool _readerActive = false;

  /// 通知鸿蒙侧当前是否处于阅读器页面（进入/离开阅读器时调用）。
  ///
  /// [active] 为 true 表示阅读器激活（可流转）；为 false 表示离开阅读器，
  /// 鸿蒙侧会同步清空缓存的阅读状态，主页等页面不再显示接续入口。
  static void setReaderActive(bool active) {
    if (_readerActive == active) return;
    _readerActive = active;
    if (!App.isOhos) return;
    try {
      _channel.invokeMethod<void>('updateContinueActive', {'active': active});
    } catch (e) {
      Log.warning("Continuation", "setReaderActive failed: $e");
    }
  }

  /// 上报当前阅读位置到鸿蒙侧缓存（源设备侧）。
  ///
  /// [cid] 漫画 id；[sourceKey] 漫画源 key；[name] 漫画名；
  /// [ep]/[page]/[group] 均为 1-based（与 History 约定一致）。
  static void reportReaderState({
    required String cid,
    required String sourceKey,
    required String name,
    required int ep,
    required int page,
    int? group,
  }) {
    if (!App.isOhos) return;
    try {
      final state = jsonEncode({
        'cid': cid,
        'sourceKey': sourceKey,
        'name': name,
        'ep': ep,
        'page': page,
        if (group != null) 'group': group,
      });
      _channel.invokeMethod<void>('updateContinueState', {'state': state});
    } catch (e) {
      Log.warning("Continuation", "reportReaderState failed: $e");
    }
  }

  /// 注册 restorePending 处理器（鸿蒙侧热启动接续时主动推送）。
  /// 应在 App 启动早期调用一次（幂等）。
  static void init() {
    if (!App.isOhos || _handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'restorePending') {
        final state = call.arguments as String?;
        if (state != null && state.isNotEmpty) {
          Log.info("Continuation", "restorePending received: $state");
          await restoreReaderState(state);
        }
      }
      return null;
    });
  }

  /// 检查并恢复待接续的阅读位置（目标设备冷启动时调用）。
  ///
  /// 从鸿蒙侧拉取接续数据，存在则跳转到对应漫画的指定章节继续阅读。
  /// 拉取后鸿蒙侧返回一次即失效，不会重复恢复。
  static Future<void> checkPendingContinuation() async {
    if (!App.isOhos) return;
    try {
      final state =
          await _channel.invokeMethod<String>('getPendingContinueState');
      if (state != null && state.isNotEmpty) {
        Log.info("Continuation", "pending state fetched: $state");
        await restoreReaderState(state);
      }
    } catch (e) {
      Log.warning("Continuation", "checkPendingContinuation failed: $e");
    }
  }

  /// 根据接续状态 JSON 跳转到对应漫画阅读器。
  ///
  /// 通过 ComicPage 打开漫画详情（保证 chapters 已加载），再自动进入
  /// 阅读器并跳到接续的章节/页码。
  static Future<void> restoreReaderState(String stateJson) async {
    try {
      // 等待所有漫画源完成初始化（含源脚本的 init()，parser 以 50ms
      // 延迟调度、不 await）。否则源运行时状态（如 baseUrl）可能尚未
      // 就绪，loadInfo 会报 "cannot read property of undefined"。
      // 冷启动（checkPendingContinuation）与热启动（restorePending）
      // 两条恢复路径都经过这里，统一等待。
      await ComicSourceManager().waitForSourcesReady();
      final data = jsonDecode(stateJson) as Map<String, dynamic>;
      final cid = data['cid'] as String?;
      final sourceKey = data['sourceKey'] as String?;
      if (cid == null || cid.isEmpty || sourceKey == null) {
        Log.warning("Continuation", "invalid state: missing cid/sourceKey");
        return;
      }
      final ep = (data['ep'] as num?)?.toInt() ?? 1;
      final page = (data['page'] as num?)?.toInt() ?? 1;
      final group = (data['group'] as num?)?.toInt();
      final context = App.rootContext;
      if (!context.mounted) {
        Log.warning("Continuation", "root context not mounted");
        return;
      }
      Log.info(
        "Continuation",
        "restore reader: cid=$cid source=$sourceKey ep=$ep page=$page group=$group",
      );
      context.to(() => ComicPage(
            id: cid,
            sourceKey: sourceKey,
            initialReadEp: ep,
            initialReadPage: page,
            initialReadGroup: group,
          ));
    } catch (e) {
      Log.error("Continuation", "restoreReaderState failed", e);
    }
  }
}
