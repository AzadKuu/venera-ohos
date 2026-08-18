import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/ext.dart';

import 'cookie_jar.dart';

class CloudflareException implements DioException {
  final String url;
  final RequestOptions? _requestOptions;

  CloudflareException(this.url, {RequestOptions? requestOptions})
      : _requestOptions = requestOptions;

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException: (.+)").firstMatch(message);
    if (match == null) return null;
    return CloudflareException(match.group(1)!);
  }

  @override
  DioException copyWith({
    RequestOptions? requestOptions,
    Response<dynamic>? response,
    DioExceptionType? type,
    Object? error,
    StackTrace? stackTrace,
    String? message,
  }) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions => _requestOptions ?? RequestOptions();

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;

  @override
  DioExceptionReadableStringBuilder? stringBuilder;
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.headers['cookie'].toString().contains('cf_clearance')) {
      options.headers['user-agent'] = appdata.implicitData['ua'] ?? webUA;
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // CloudflareException 从 onResponse reject 传来，没有 response 属性
    if (err is CloudflareException) {
      var cfErr = err;
      // 如果有活跃的 webview proxy，用 proxy fetch 重新请求（自动带 HttpOnly cookie）
      if (CloudflareProxy.channel != null &&
          CloudflareProxy.proxyHost != null &&
          Uri.parse(cfErr.url).host == CloudflareProxy.proxyHost) {
        try {
          var response = await CloudflareProxy.proxyFetch(cfErr.requestOptions);
          handler.resolve(response);
          return;
        } catch (e, s) {
          Log.error("Cloudflare", "proxy fetch failed: $e", s);
          // proxy 失败，回退到正常 cloudflare 错误
        }
      }
      handler.next(cfErr);
      return;
    }
    if (err.response?.statusCode == 403) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    if (response.statusCode == 403) {
      var err = _check(response);
      if (err != null) {
        // 如果有活跃的 webview proxy，用 proxy fetch 重新请求（自动带 HttpOnly cookie）
        if (CloudflareProxy.channel != null &&
            CloudflareProxy.proxyHost != null &&
            Uri.parse(err.url).host == CloudflareProxy.proxyHost) {
          try {
            var proxyResponse =
                await CloudflareProxy.proxyFetch(response.requestOptions);
            handler.resolve(proxyResponse);
            return;
          } catch (e, s) {
            Log.error("Cloudflare", "proxy fetch failed: $e", s);
            // proxy 失败，回退到正常 cloudflare 错误
          }
        }
        handler.reject(err);
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      return CloudflareException(
        response.requestOptions.uri.toString(),
        requestOptions: response.requestOptions,
      );
    }
    return null;
  }
}

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  var url = e.url;
  var uri = Uri.parse(url);

  void saveCookies(Map<String, String> cookies) {
    var domain = uri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    SingleInstanceCookieJar.instance!.saveFromResponse(
      uri,
      List<io.Cookie>.generate(cookies.length, (index) {
        var cookie = io.Cookie(
          cookies.keys.elementAt(index),
          cookies.values.elementAt(index),
        );
        cookie.domain = domain;
        return cookie;
      }),
    );
  }

  // windows version of package `flutter_inappwebview` cannot get some cookies
  // Using DesktopWebview instead
  if (App.isLinux) {
    var webview = DesktopWebview(
      initialUrl: url,
      onTitleChange: (title, controller) async {
        var head =
            await controller.evaluateJavascript("document.head.innerHTML") ??
            "";
        var body =
            await controller.evaluateJavascript("document.body.innerHTML") ??
            "";
        Log.info("Cloudflare", "Checking head: $head");
        var isChallenging =
            head.contains('#challenge-success-text') ||
            head.contains("#challenge-error-text") ||
            head.contains("#challenge-form") ||
            body.contains("challenge-platform") ||
            body.contains("window._cf_chl_opt");
        if (!isChallenging) {
          Log.info(
            "Cloudflare",
            "Cloudflare is passed due to there is no challenge css",
          );
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookiesMap = await controller.getCookies(url);
          if (cookiesMap['cf_clearance'] == null) {
            return;
          }
          saveCookies(cookiesMap);
          controller.close();
          onFinished();
        }
      },
      onClose: onFinished,
    );
    webview.open();
  } else {
    if (App.isOhos) {
      await _passCloudflareOhos(url, onFinished);
      return;
    }
    bool success = false;
    void check(InAppWebViewController controller) async {
      var head =
          await controller.evaluateJavascript(source: "document.head.innerHTML")
              as String;
      var body =
          await controller.evaluateJavascript(source: "document.body.innerHTML")
              as String;
      Log.info("Cloudflare", "Checking head: $head");
      var isChallenging =
          head.contains('#challenge-success-text') ||
          head.contains("#challenge-error-text") ||
          head.contains("#challenge-form") ||
          body.contains("challenge-platform") ||
          body.contains("window._cf_chl_opt");
      if (!isChallenging) {
        Log.info(
          "Cloudflare",
          "Cloudflare is passed due to there is no challenge css",
        );
        var ua = await controller.getUA();
        if (ua != null) {
          appdata.implicitData['ua'] = ua;
          appdata.writeImplicitData();
        }
        var cookies = await controller.getCookies(url) ?? [];
        if (cookies.firstWhereOrNull(
              (element) => element.name == 'cf_clearance',
            ) ==
            null) {
          return;
        }
        SingleInstanceCookieJar.instance?.saveFromResponse(uri, cookies);
        if (!success) {
          App.rootPop();
          success = true;
        }
      }
    }

    await App.rootContext.to(
      () => AppWebview(
        initialUrl: url,
        singlePage: true,
        onTitleChange: (title, controller) async {
          check(controller);
        },
        onLoadStop: (controller) async {
          check(controller);
        },
        onStarted: (controller) async {
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var cookies = await controller.getCookies(url) ?? [];
          SingleInstanceCookieJar.instance?.saveFromResponse(uri, cookies);
        },
      ),
    );
    onFinished();
  }
}

/// 解码 runJavaScript 返回值。
/// 鸿蒙 runJavaScript 返回 JSON 编码字符串：JS 返回 "hello" → 返回 '"hello"'。
/// 需要去掉首尾引号才能得到实际值。
String decodeJsResult(dynamic result) {
  if (result == null) return '';
  var raw = result.toString();
  if (raw.isEmpty) return '';
  if (raw.startsWith('"') && raw.endsWith('"')) {
    try {
      return jsonDecode(raw) as String;
    } catch (_) {
      // jsonDecode 失败，手动去掉首尾引号
      return raw.substring(1, raw.length - 1);
    }
  }
  return raw;
}

/// 鸿蒙专用：用 venera/webview channel + 鸿蒙原生 Web 组件过 Cloudflare challenge。
/// flutter_inappwebview 无鸿蒙实现，改用 EntryAbility 注册的 venera/webview channel。
Future<void> _passCloudflareOhos(String url, void Function() onFinished) async {
  Log.info("Cloudflare", "ohos passCloudflare start, url=$url");
  final channel = MethodChannel('venera/webview');
  bool success = false;
  var uri = Uri.parse(url);
  Timer? timer;

  // 用 IIFE 包装确保 runJavaScript 可靠返回字符串，head/body 为 null 时不抛异常。
  const headScript =
      '(function(){try{return document.head?document.head.innerHTML:"";}catch(e){return "";}})()';
  const bodyScript =
      '(function(){try{return document.body?document.body.innerHTML:"";}catch(e){return "";}})()';
  const uaScript =
      '(function(){try{return navigator.userAgent||"";}catch(e){return "";}})()';
  const titleScript =
      '(function(){try{return document.title||"";}catch(e){return "";}})()';

  Future<void> check() async {
    if (success) return;
    try {
      var head = await channel.invokeMethod('evaluateJavaScript', {
        'script': headScript,
      }) ?? '';
      var body = await channel.invokeMethod('evaluateJavaScript', {
        'script': bodyScript,
      }) ?? '';
      var title = await channel.invokeMethod('evaluateJavaScript', {
        'script': titleScript,
      }) ?? '';
      var headStr = decodeJsResult(head);
      var bodyStr = decodeJsResult(body);
      var titleStr = decodeJsResult(title);
      Log.info(
        "Cloudflare",
        "ohos check head.len=${headStr.length} body.len=${bodyStr.length} title=$titleStr",
      );
      // challenge 进行中的可靠标志。
      // 注意：去掉宽泛的 "challenge-platform"——cf 在受保护的目标页也会注入
      // challenge-platform 脚本，会导致 challenge 通过后仍误判为 challenging。
      // 加 "Just a moment" 标题检测：challenge 进行中页标题是 "Just a moment..."，
      // 通过后变成目标页标题，这是最可靠的进行中标志。
      var isChallenging =
          headStr.contains('#challenge-form') ||
          headStr.contains('#challenge-success-text') ||
          headStr.contains('#challenge-error-text') ||
          bodyStr.contains('#challenge-form') ||
          bodyStr.contains('window._cf_chl_opt') ||
          titleStr.contains('Just a moment');
      if (isChallenging) return;
      if (titleStr.isEmpty) return; // 页面还没加载
      // challenge 已通过（title 不是 "Just a moment"，页面已加载）。
      // 不依赖 cookie 获取：arkweb core API level 0 导致 WebCookieManager 不工作，
      // document.cookie 读不到 HttpOnly cookie（cf_clearance 通常 HttpOnly）。
      // 改为保持 Web 组件活跃，后续 403 请求通过 proxy fetch 代理（自动带 HttpOnly cookie）。
      Log.info("Cloudflare", "ohos: cloudflare passed, setting up proxy");
      var ua = await channel.invokeMethod('evaluateJavaScript', {
        'script': uaScript,
      });
      var uaStr = decodeJsResult(ua);
      if (uaStr.isNotEmpty) {
        appdata.implicitData['ua'] = uaStr;
        appdata.writeImplicitData();
      }
      success = true;
      timer?.cancel();
      // 隐藏 webview 但不销毁，保持 Web 组件用于 proxy fetch
      await channel.invokeMethod('hide');
      CloudflareProxy.channel = channel;
      CloudflareProxy.proxyHost = uri.host;
      channel.setMethodCallHandler(null);
      onFinished();
    } catch (e, s) {
      Log.error("Cloudflare", "ohos check failed: $e", s);
    }
  }

  // 事件驱动 check（onNavigation/onTitleChange/onPageEnd）。
  channel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onNavigation':
      case 'onTitleChange':
      case 'onPageEnd':
        await check();
        break;
    }
    return null;
  });

  // 定时轮询兜底：challenge 通过后若事件未触发（原地 DOM 更新、标题未变等），
  // 轮询仍能检测到通过并关闭窗口。
  timer = Timer.periodic(const Duration(milliseconds: 1500), (t) {
    if (success) {
      t.cancel();
      return;
    }
    check();
  });

  // 超时自动关闭，避免永久卡住。
  Future.delayed(const Duration(seconds: 120), () {
    if (success) return;
    success = true;
    timer?.cancel();
    channel.setMethodCallHandler(null);
    channel.invokeMethod('close');
    Log.warning("Cloudflare", "ohos: timeout (120s), closing webview");
    onFinished();
  });

  await channel.invokeMethod('open', {'url': url});
  Log.info("Cloudflare", "ohos webview open returned, polling started");
}

/// Web 组件 HTTP 代理。
///
/// Cloudflare challenge 通过后，Web 组件保持活跃（隐藏不销毁）。
/// 后续 403 请求通过 Web 组件的 `fetch` 执行，自动带 HttpOnly cookie
/// （cf_clearance 等），无需把 cookie 提取到 Dart 侧。
///
/// arkweb core API level 0 导致 WebCookieManager.fetchCookieSync 不工作，
/// document.cookie 读不到 HttpOnly cookie，这是唯一可行的 cookie 传递方案。
class CloudflareProxy {
  static MethodChannel? channel;
  static String? proxyHost;

  /// 通过 Web 组件的 fetch 代理请求。
  ///
  /// [options] 是 dio 的 RequestOptions，包含 url、method、headers 等。
  /// 返回构造的 dio Response。
  static Future<Response> proxyFetch(RequestOptions options) async {
    var url = options.uri.toString();
    var method = options.method.toUpperCase();
    Log.info("Cloudflare", "proxy fetch: $method $url");

    // 转义 URL 中的特殊字符，防止破坏 JS 字符串
    var safeUrl = url
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n');

    // 构造 fetch JS。结果存 window.__proxyResult，轮询读取。
    // fetch credentials:'include' 确保带 cookie（包括 HttpOnly）。
    var fetchJs = '''
(async function() {
  try {
    const r = await fetch("\$safeUrl", {method: "\$method", credentials: "include", redirect: "follow"});
    const text = await r.text();
    window.__proxyResult = JSON.stringify({status: r.status, body: text});
  } catch(e) {
    window.__proxyResult = JSON.stringify({error: String(e)});
  }
})()
''';

    await channel!.invokeMethod('evaluateJavaScript', {'script': fetchJs});

    // 轮询结果（每 200ms，最多 30s）
    for (var i = 0; i < 150; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      var result = await channel!.invokeMethod('evaluateJavaScript', {
        'script': '(function(){try{return window.__proxyResult||null;}catch(e){return null;}})()',
      });
      if (result == null) continue;
      var raw = result.toString();
      if (raw.isEmpty || raw == 'null' || raw == '""') continue;

      // 清除结果
      await channel!.invokeMethod('evaluateJavaScript', {
        'script': '(function(){try{window.__proxyResult=null;}catch(e){}})()',
      });

      // runJavaScript 返回 JSON 编码字符串，解码第一层
      String jsonStr;
      if (raw.startsWith('"') && raw.endsWith('"')) {
        try {
          jsonStr = jsonDecode(raw) as String;
        } catch (_) {
          jsonStr = raw.substring(1, raw.length - 1);
        }
      } else {
        jsonStr = raw;
      }

      Map<String, dynamic> json;
      try {
        json = jsonDecode(jsonStr) as Map<String, dynamic>;
      } catch (e) {
        Log.error("Cloudflare", "proxy fetch json decode failed: $e, raw=$jsonStr");
        throw Exception('Proxy fetch json decode failed');
      }

      if (json.containsKey('error')) {
        throw Exception('Proxy fetch error: ${json['error']}');
      }

      var status = json['status'] as int;
      var body = json['body'] as String;
      Log.info("Cloudflare", "proxy fetch result: status=$status body.len=${body.length}");

      // 解析 body：JSON 字符串转 Map/List，否则保持 String
      dynamic data;
      if (body.isNotEmpty && (body[0] == '{' || body[0] == '[')) {
        try {
          data = jsonDecode(body);
        } catch (_) {
          data = body;
        }
      } else {
        data = body;
      }

      return Response(
        requestOptions: options,
        statusCode: status,
        data: data,
        headers: Headers.fromMap({}),
        isRedirect: false,
        extra: {'proxyFetch': true},
      );
    }
    throw Exception('Proxy fetch timeout (30s)');
  }

  /// 关闭 proxy 并销毁 Web 组件。
  static Future<void> close() async {
    if (channel != null) {
      try {
        await channel!.invokeMethod('close');
      } catch (_) {}
    }
    channel = null;
    proxyHost = null;
  }
}
