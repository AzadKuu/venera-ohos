import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/proxy.dart';

/// HarmonyOS 专用的 [HttpClientAdapter]。
///
/// rhttp（flutter_rust_bridge）需要把 Rust 代码编译成 `.so` 才能通过 FFI 加载，
/// 但鸿蒙工程里从未编译过 rhttp 的 Rust 库，导致 `RustLib.init()` 无法工作
/// （日志：codegen version 不匹配 / 找不到动态库），HTTP 层整体不可用。
///
/// 鸿蒙上改用 Dart 标准库 `dart:io` 的 [HttpClient] 实现，功能对齐
/// [RHttpAdapter] 的关键能力：代理、连接超时、TLS 校验开关。
class OhosHttpAdapter implements HttpClientAdapter {
  OhosHttpAdapter({this.enableProxy = true});

  final bool enableProxy;

  String? _proxy;

  Future<void> _refreshProxy() async {
    _proxy = enableProxy ? await getProxy() : null;
  }

  /// 校验证书是否放行。
  bool _allowCertificate(X509Certificate? cert, String host, int port) {
    // ignoreBadCertificate == true 时跳过校验
    return appdata.settings['ignoreBadCertificate'] == true;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    try {
      return await _fetchInner(options, requestStream, cancelFuture);
    } catch (e, s) {
      // 鸿蒙调试用：直接打印原始异常，避免被 dio 拦截器链吞掉
      Log.error(
        "OhosHttpAdapter",
        "${options.method} ${options.uri}\n$e\n$s",
      );
      rethrow;
    }
  }

  Future<ResponseBody> _fetchInner(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await _refreshProxy();
    final httpClient = _createHttpClient(options.connectTimeout);
    final reqFuture = httpClient.openUrl(options.method, options.uri);
    late HttpClientRequest request;
    try {
      final connectionTimeout = options.connectTimeout;
      if (connectionTimeout != null && connectionTimeout > Duration.zero) {
        request = await reqFuture.timeout(
          connectionTimeout,
          onTimeout: () {
            throw DioException.connectionTimeout(
              requestOptions: options,
              timeout: connectionTimeout,
            );
          },
        );
      } else {
        request = await reqFuture;
      }

      final requestWR = WeakReference<HttpClientRequest>(request);
      cancelFuture?.whenComplete(() {
        requestWR.target?.abort();
      });

      // 设置请求头
      options.headers.forEach((key, value) {
        if (value != null) {
          request.headers.set(
            key,
            value,
            preserveHeaderCase: options.preserveHeaderCase,
          );
        }
      });
    } on SocketException catch (e) {
      if (e.message.contains('timed out')) {
        throw DioException.connectionTimeout(
          requestOptions: options,
          timeout: options.connectTimeout ?? Duration.zero,
          error: e,
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: e.message,
        error: e,
      );
    }

    request.followRedirects = options.followRedirects;
    request.maxRedirects = options.maxRedirects;
    request.persistentConnection = options.persistentConnection;

    if (requestStream != null) {
      Future<dynamic> future = request.addStream(requestStream);
      final sendTimeout = options.sendTimeout;
      if (sendTimeout != null && sendTimeout > Duration.zero) {
        future = future.timeout(
          sendTimeout,
          onTimeout: () {
            request.abort();
            throw DioException.sendTimeout(
              timeout: sendTimeout,
              requestOptions: options,
            );
          },
        );
      }
      await future;
    }

    Future<HttpClientResponse> future = request.close();
    final receiveTimeout = options.receiveTimeout ?? Duration.zero;
    if (receiveTimeout > Duration.zero) {
      future = future.timeout(
        receiveTimeout,
        onTimeout: () {
          request.abort();
          throw DioException.receiveTimeout(
            timeout: receiveTimeout,
            requestOptions: options,
          );
        },
      );
    }
    late final HttpClientResponse responseStream;
    try {
      responseStream = await future;
    } on HttpException catch (e, s) {
      if (e.message.contains(
        'Connection closed before full header was received',
      )) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: e.message,
          error: e,
          stackTrace: s,
        );
      }
      rethrow;
    }

    final headers = <String, List<String>>{};
    responseStream.headers.forEach((key, values) {
      headers[key] = values;
    });

    final responseBody = ResponseBody(
      responseStream.cast(),
      responseStream.statusCode,
      headers: headers,
      isRedirect:
          responseStream.isRedirect || responseStream.redirects.isNotEmpty,
      redirects: responseStream.redirects
          .map((e) => RedirectRecord(e.statusCode, e.method, e.location))
          .toList(),
      statusMessage: responseStream.reasonPhrase,
    );
    return responseBody;
  }

  HttpClient _createHttpClient(Duration? connectionTimeout) {
    final client = HttpClient()..idleTimeout = const Duration(seconds: 60);
    if (connectionTimeout != null && connectionTimeout > Duration.zero) {
      client.connectionTimeout = connectionTimeout;
    }
    // 代理：dart:io 的 findProxy 是同步回调，使用预取的代理字符串
    final proxy = _proxy;
    if (proxy != null && proxy.isNotEmpty) {
      client.findProxy = (uri) => 'PROXY $proxy';
    }
    client.badCertificateCallback = _allowCertificate;
    return client;
  }

  @override
  void close({bool force = false}) {
    // dart:io HttpClient 无全局关闭入口（每个请求独立创建），无需处理
  }
}
