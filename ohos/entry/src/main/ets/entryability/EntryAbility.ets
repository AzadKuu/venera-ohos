
import { FlutterAbility, FlutterEngine, FlutterManager, MethodChannel, MethodCall, MethodResult, BasicMessageChannel, BinaryCodec, Reply, Log } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import i18n from '@ohos.i18n';
import picker from '@ohos.file.picker';
import fs from '@ohos.file.fs';
import window from '@ohos.window';
import web_webview from '@ohos.web.webview';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import image from '@ohos.multimedia.image';
import imageSuperResolution from '@hms.ai.vision.imageSuperResolution';
import visionBase from '@hms.ai.vision.visionBase';
import { WebviewBridge } from '../webview/WebviewBridge';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import motion from '@ohos.multimodalAwareness.motion';

const TAG = "EntryAbility";

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // initializeWebEngine 延迟到第一次打开 webview 时调（open handler 里），
    // 避免启动时加载 web engine 库拖慢冷启动。
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    this.registerPathProvider(flutterEngine)
    this.registerSystemInfo(flutterEngine)
    this.registerFileDialog(flutterEngine)
    this.registerFileSelector(flutterEngine)
    this.registerWebview(flutterEngine)
    this.registerUrlLauncher(flutterEngine)
    this.registerAiSuperResolution(flutterEngine)
    this.registerAiSuperResolutionBin(flutterEngine)
    this.registerContinuation(flutterEngine)
    this.registerSmartGrip(flutterEngine)
  }

  /**
   * AI 超分引擎实例。懒加载并复用（模型加载开销大），随 Ability 生命周期存在。
   */
  private aiSrAnalyzer: imageSuperResolution.ImageSRAnalyzer | null = null;

  /**
   * AI 超分请求串行队列。Core Vision 端侧引擎不支持并发推理，
   * 阅读器会同时预载多张图，通过 promise 链把请求排队。
   */
  private aiSrQueue: Promise<void> = Promise.resolve();

  /**
   * 应用接续：源设备侧缓存的当前阅读位置（JSON 字符串）。
   * Flutter 阅读器翻页/切章时通过 venera/continuation channel 的
   * updateContinueState 方法主动上报，鸿蒙侧缓存此字段。
   * onContinue 被系统调用时直接读取并写入 wantParam，无需等待引擎通信。
   */
  private continueState: string | null = null;

  /**
   * 应用接续：当前是否处于支持接续的页面（阅读器）。
   * Flutter 侧进入/离开阅读器时通过 updateContinueActive 上报。
   * onContinue 只有在该标志为 true 且 continueState 非空时才 AGREE，
   * 避免主页等不支持接续的页面误显示接续入口。
   */
  private continueActive: boolean = false;

  /**
   * 应用接续：目标设备侧待恢复的阅读位置（JSON 字符串）。
   * 系统通过 onContinue -> want 把源设备状态带到目标设备，onCreate/onNewWant
   * 里读取 want.parameters 中的接续数据暂存于此。Flutter 启动后通过
   * getPendingContinueState 主动拉取并恢复阅读位置。
   */
  private pendingContinueState: string | null = null;

  /**
   * want.parameters 中接续数据的 key。源设备 onContinue 写入 wantParam，
   * 系统会原样带到目标设备的 want.parameters。
   */
  private static readonly CONTINUE_STATE_KEY = "venera_continue_state";

  /**
   * venera/continuation channel 实例。注册后保存引用，供热启动接续时
   * 主动向 Dart 侧推送待恢复状态（invokeMethod 需要同一个 channel）。
   */
  private continuationChannel: MethodChannel | null = null;

  /**
   * 实现 path_provider 插件的 method channel（plugins.flutter.io/path_provider）。
   *
   * 标准 path_provider 插件没有鸿蒙原生实现，若不注册此 handler，Dart 侧
   * getApplicationSupportDirectory()/getApplicationCacheDirectory() 会抛
   * MissingPluginException，导致 App.init() 中 dataPath/cachePath 无法初始化。
   */
  private registerPathProvider(flutterEngine: FlutterEngine): void {
    const context = this.context;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'plugins.flutter.io/path_provider');
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        Log.i(TAG, "path_provider method: " + call.method);
        switch (call.method) {
          // 注意：方法名必须与 Dart 端 MethodChannelPathProvider 完全一致
          // （path_provider_platform_interface 2.1.3 调用的是 Directory 后缀名，
          //  不是 *Path 后缀名），否则会落入 default 返回 notImplemented，
          //  Dart 侧收到 MissingPluginException。
          case 'getApplicationSupportDirectory':
            result.success(context.filesDir);
            break;
          case 'getApplicationCacheDirectory':
            result.success(context.cacheDir);
            break;
          case 'getTemporaryDirectory':
            result.success(context.tempDir);
            break;
          case 'getApplicationDocumentsDirectory':
            result.success(context.filesDir);
            break;
          case 'getLibraryDirectory':
            result.success(context.filesDir);
            break;
          case 'getStorageDirectory':
          case 'getExternalCacheDirectories':
          case 'getExternalStorageDirectories':
          case 'getDownloadsDirectory':
            // 鸿蒙没有直接对应的外部存储/下载目录，返回 null（Dart 侧为 Directory?）
            result.success(null);
            break;
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "path_provider channel registered");
  }

  /**
   * 注册 venera/system_info channel，提供系统信息（如系统 locale）。
   *
   * 鸿蒙 Flutter 引擎的 PlatformDispatcher.instance.locale 在某些情况下未正确反映
   * 系统语言（返回 en），Dart 侧 App.init() 通过此 channel 主动调
   * i18n.System.getSystemLocale() 获取真实系统语言（BCP47，如 zh-Hans-CN）。
   */
  private registerSystemInfo(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'venera/system_info');
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        switch (call.method) {
          case 'getSystemLocale':
            try {
              const locale: string = i18n.System.getSystemLocale();
              Log.i(TAG, "getSystemLocale -> " + locale);
              result.success(locale);
            } catch (e) {
              Log.e(TAG, "getSystemLocale failed: " + JSON.stringify(e));
              result.success(null);
            }
            break;
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "system_info channel registered");
  }

  /**
   * 实现 flutter_file_dialog 插件的 method channel（flutter_file_dialog）。
   *
   * 标准 flutter_file_dialog 插件没有鸿蒙原生实现，saveFile 会抛
   * MissingPluginException。此处用鸿蒙 @ohos.file.picker 的 DocumentViewPicker
   * 实现保存文件对话框：拉起系统文件选择器让用户选保存位置，再把源文件内容
   * 复制到目标 URI。
   *
   * Dart 侧 FlutterFileDialog.saveFile(params) 传 {sourceFilePath, data, fileName, ...}，
   * 此处只处理 sourceFilePath（io.dart 的 saveFile 总是先把 data 写缓存文件再传
   * sourceFilePath），返回保存后的 URI 字符串或 null（用户取消）。
   */
  private registerFileDialog(flutterEngine: FlutterEngine): void {
    const context = this.context;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'flutter_file_dialog');
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        switch (call.method) {
          case 'saveFile': {
            const sourceFilePath: string = call.argument('sourceFilePath');
            const fileName: string = call.argument('fileName');
            Log.i(TAG, "saveFile sourceFilePath=" + sourceFilePath + " fileName=" + fileName);
            const documentPicker = new picker.DocumentViewPicker(context);
            const options = new picker.DocumentSaveOptions();
            if (fileName != null && fileName.length > 0) {
              options.newFileNames = [fileName];
            }
            documentPicker.save(options).then((uris: Array<string>) => {
              if (uris == null || uris.length == 0) {
                result.success(null);
                return;
              }
              const dstUri = uris[0];
              try {
                const dstFile = fs.openSync(dstUri, fs.OpenMode.READ_WRITE);
                if (sourceFilePath != null && sourceFilePath.length > 0) {
                  const srcFile = fs.openSync(sourceFilePath, fs.OpenMode.READ_ONLY);
                  fs.copyFileSync(srcFile.fd, dstFile.fd);
                  fs.closeSync(srcFile);
                }
                fs.closeSync(dstFile);
                Log.i(TAG, "saveFile saved to " + dstUri);
                result.success(dstUri);
              } catch (e) {
                Log.e(TAG, "saveFile write failed: " + JSON.stringify(e));
                result.success(null);
              }
            }).catch((err: Error) => {
              Log.i(TAG, "saveFile cancelled or failed: " + JSON.stringify(err));
              result.success(null);
            });
            break;
          }
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "flutter_file_dialog channel registered");
  }

  /**
   * 实现 file_selector 插件的 method channel（plugins.flutter.io/file_selector）。
   *
   * 标准 file_selector 插件没有鸿蒙原生实现，openFile/getDirectoryPath 会抛
   * MissingPluginException。此处用鸿蒙 @ohos.file.picker 的 DocumentViewPicker 实现：
   * - openFile：select() 选文件，把选中文件复制到 App cacheDir，返回缓存路径数组
   *   （Dart 侧 file_selector.openFile 用 invokeListMethod 期望 List<String> 路径）。
   * - getDirectoryPath：select(FOLDER 模式) 选目录，返回 URI。
   *
   * 注意：picker 返回的是 URI（file://docs/...），Dart 侧 File/Directory 不能直接访问，
   * 故 openFile 把文件复制到 App 沙箱 cacheDir 再返回路径。
   */
  private registerFileSelector(flutterEngine: FlutterEngine): void {
    const context = this.context;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'plugins.flutter.io/file_selector');
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        switch (call.method) {
          case 'openFile': {
            const documentPicker = new picker.DocumentViewPicker(context);
            const options = new picker.DocumentSelectOptions();
            documentPicker.select(options).then((uris: Array<string>) => {
              if (uris == null || uris.length == 0) {
                result.success(null);
                return;
              }
              try {
                const paths: Array<string> = [];
                for (let i = 0; i < uris.length; i++) {
                  const uri = uris[i];
                  let name = uri.substring(uri.lastIndexOf('/') + 1);
                  try {
                    name = decodeURIComponent(name);
                  } catch (e) {
                    // ignore decode error
                  }
                  const destPath = context.cacheDir + '/' + name;
                  const srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
                  fs.copyFileSync(srcFile.fd, destPath);
                  fs.closeSync(srcFile);
                  paths.push(destPath);
                }
                Log.i(TAG, "openFile copied " + paths.length + " files");
                result.success(paths);
              } catch (e) {
                Log.e(TAG, "openFile copy failed: " + JSON.stringify(e));
                result.success(null);
              }
            }).catch((err: Error) => {
              Log.i(TAG, "openFile cancelled: " + JSON.stringify(err));
              result.success(null);
            });
            break;
          }
          case 'getDirectoryPath': {
            const documentPicker = new picker.DocumentViewPicker(context);
            const options = new picker.DocumentSelectOptions();
            options.selectMode = picker.DocumentSelectMode.FOLDER;
            documentPicker.select(options).then((uris: Array<string>) => {
              if (uris == null || uris.length == 0) {
                result.success(null);
                return;
              }
              Log.i(TAG, "getDirectoryPath -> " + uris[0]);
              result.success(uris[0]);
            }).catch((err: Error) => {
              Log.i(TAG, "getDirectoryPath cancelled: " + JSON.stringify(err));
              result.success(null);
            });
            break;
          }
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "file_selector channel registered");
  }

  /**
   * 注册 venera/webview channel，用鸿蒙 @ohos.web.webview 实现漫画源登录 webview。
   *
   * flutter_inappwebview 无鸿蒙实现，venera 的 loginWithWebview 在鸿蒙上改用此 channel：
   * - open(url)：创建子窗口加载 pages/WebviewPage（全屏 Web 组件）。
   * - getCookies(url)：用 WebCookieManager.fetchCookieSync 返回 "name=value; ..." 字符串。
   * - getLocalStorage：用 controller.runJavaScript 注入 JS 读取 localStorage JSON。
   * - close：销毁子窗口。
   *
   * WebviewPage 的 onLoadIntercept/onTitleReceive 事件通过 WebviewBridge.channel 回传
   * Dart 侧（onNavigation/onTitleChange）。
   */
  private registerWebview(flutterEngine: FlutterEngine): void {
    const context = this.context;
    const ability = this;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'venera/webview');
    WebviewBridge.channel = channel;
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        switch (call.method) {
          case 'open': {
            const url: string = call.argument('url');
            WebviewBridge.currentUrl = url;
            Log.i(TAG, "webview open: " + url);
            // 延迟到第一次打开 webview 时才初始化 web engine，避免启动时加载拖慢冷启动。
            try {
              web_webview.WebviewController.initializeWebEngine();
              Log.i(TAG, "initializeWebEngine ok");
            } catch (e) {
              Log.e(TAG, "initializeWebEngine failed: " + JSON.stringify(e));
            }
            const windowStage = FlutterManager.getInstance().getWindowStage(ability);
            windowStage.createSubWindow('WebviewWindow')
              .then((win: window.Window) => {
                WebviewBridge.subWindow = win;
                return win.loadContent('pages/WebviewPage');
              })
              .then(() => {
                return WebviewBridge.subWindow!.showWindow();
              })
              .then(() => {
                result.success(null);
              })
              .catch((err: Error) => {
                Log.e(TAG, "webview openWindow failed: " + JSON.stringify(err));
                result.success(null);
              });
            break;
          }
          case 'getCookies': {
            const url: string = call.argument('url');
            try {
              const cookie = web_webview.WebCookieManager.fetchCookieSync(url);
              Log.i(TAG, "getCookies: " + cookie);
              result.success(cookie);
            } catch (e) {
              Log.e(TAG, "getCookies failed: " + JSON.stringify(e));
              result.success('');
            }
            break;
          }
          case 'evaluateJavaScript': {
            const script: string = call.argument('script');
            const controller = WebviewBridge.controller;
            if (controller == null || script == null) {
              result.success(null);
              return;
            }
            controller.runJavaScript(script).then((res: string) => {
              result.success(res);
            }).catch((err: Error) => {
              Log.e(TAG, "evaluateJavaScript failed: " + JSON.stringify(err));
              result.success(null);
            });
            break;
          }
          case 'getLocalStorage': {
            const controller = WebviewBridge.controller;
            if (controller == null) {
              result.success('{}');
              return;
            }
            controller.runJavaScript(
              `(function(){var o={};for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);o[k]=localStorage.getItem(k);}return JSON.stringify(o);})()`
            ).then((json: string) => {
              result.success(json != null ? json : '{}');
            }).catch((err: Error) => {
              Log.e(TAG, "getLocalStorage failed: " + JSON.stringify(err));
              result.success('{}');
            });
            break;
          }
          case 'hide': {
            // 鸿蒙 Window 没有 hideWindow，用 resize(1,1) + moveWindowTo(-100,-100)
            // 移到屏幕外，保持 Web 组件活跃用于 proxy fetch。
            if (WebviewBridge.subWindow != null) {
              WebviewBridge.subWindow!.resize(1, 1).then(() => {
                return WebviewBridge.subWindow!.moveWindowTo(-100, -100);
              }).then(() => {
                Log.i(TAG, "webview hidden (moved offscreen)");
              }).catch((e: Error) => {
                Log.e(TAG, "hide: resize/move failed: " + JSON.stringify(e));
              });
            }
            try {
              const ws = FlutterManager.getInstance().getWindowStage(ability);
              const mainWindow = ws.getMainWindowSync();
              mainWindow.showWindow();
            } catch (e) {
              Log.e(TAG, "hide: showMainWindow failed: " + JSON.stringify(e));
            }
            result.success(null);
            break;
          }
          case 'close': {
            if (WebviewBridge.subWindow != null) {
              WebviewBridge.subWindow!.destroyWindow();
              WebviewBridge.subWindow = null;
            }
            WebviewBridge.controller = null;
            // 子窗口销毁后，显式恢复主窗口（Flutter）前台焦点
            try {
              const ws = FlutterManager.getInstance().getWindowStage(ability);
              const mainWindow = ws.getMainWindowSync();
              mainWindow.showWindow();
            } catch (e) {
              Log.e(TAG, "close: showMainWindow failed: " + JSON.stringify(e));
            }
            result.success(null);
            break;
          }
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "venera/webview channel registered");
  }

  /**
   * 实现 url_launcher 插件的 method channel（plugins.flutter.io/url_launcher）。
   *
   * 标准 url_launcher 插件没有鸿蒙原生实现（GeneratedPluginRegistrant 为空），
   * 不注册此 handler 时 Dart 侧 launchUrlString() 会抛 MissingPluginException，
   * 导致点击链接打不开。此处用鸿蒙 startAbility 调起系统浏览器打开 URL。
   */
  private registerUrlLauncher(flutterEngine: FlutterEngine): void {
    const context: common.UIAbilityContext = this.context;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'plugins.flutter.io/url_launcher');
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        switch (call.method) {
          case 'launch': {
            const url: string = call.argument('url');
            Log.i(TAG, "url_launcher launch: " + url);
            if (url == null || url.length == 0) {
              result.success(false);
              break;
            }
            try {
              context.startAbility({
                action: 'ohos.want.action.viewData',
                entities: ['entity.system.browsable'],
                uri: url
              }).then(() => {
                Log.i(TAG, "url_launcher launch ok");
                result.success(true);
              }).catch((err: Error) => {
                Log.e(TAG, "url_launcher launch failed: " + JSON.stringify(err));
                result.success(false);
              });
            } catch (e) {
              Log.e(TAG, "url_launcher launch exception: " + JSON.stringify(e));
              result.success(false);
            }
            break;
          }
          case 'canLaunch': {
            const url: string = call.argument('url');
            // 简单判断：http/https 协议由系统浏览器处理，视为可打开
            const ok = url != null &&
              (url.startsWith('http://') || url.startsWith('https://'));
            result.success(ok);
            break;
          }
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "url_launcher channel registered");
  }

  /**
   * 注册 venera/ai_super_resolution channel，用鸿蒙 Core Vision Kit 的
   * ImageSuperResolution（端侧 AI 超分）增强漫画图片。
   *
   * Dart 侧 ReaderImageProvider.load() 拿到原图字节后调用 superResolve，
   * 鸿蒙侧把字节解码为 PixelMap -> AI 超分 -> 重新编码为 JPEG 字节返回。
   * 任何一步失败都返回 null，Dart 侧自动降级为原图。
   *
   * 方法：
   * - ping：探测 channel 是否可用（Dart 侧用于跨平台判断 isAvailable）。
   * - superResolve：入参 { data: Uint8Array }（原图字节），
   *   返回 Uint8Array（增强后 JPEG 字节）或 null。
   */
  private registerAiSuperResolution(flutterEngine: FlutterEngine): void {
    const ability = this;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'venera/ai_super_resolution');
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        switch (call.method) {
          case 'ping':
            result.success(null);
            break;
          case 'superResolve': {
            const data = call.argument('data') as Uint8Array;
            if (data == null || data.length == 0) {
              result.success(null);
              break;
            }
            // Uint8Array 可能带 byteOffset，复制出干净的 ArrayBuffer 再解码
            const buffer = new ArrayBuffer(data.byteLength);
            new Uint8Array(buffer).set(data);
            ability.aiSrQueue = ability.aiSrQueue.then(async () => {
              const out = await ability.aiSuperResolve(buffer);
              result.success(out);
            }).catch((err: Error) => {
              Log.e(TAG, "ai superResolve failed: " + JSON.stringify(err));
              result.success(null);
            });
            break;
          }
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "ai_super_resolution channel registered");
  }

  /**
   * 注册 AI 超分二进制通道（venera/ai_super_resolution_bin）。
   *
   * 与 registerAiSuperResolution 的 ping MethodChannel 配合：ping 走
   * MethodChannel（低频探测），superResolve 走 BasicMessageChannel +
   * BinaryCodec（热路径，零序列化传 ArrayBuffer，省掉 MethodChannel 对
   * 大图片字节的 JSON 编码与中间拷贝）。
   */
  private registerAiSuperResolutionBin(flutterEngine: FlutterEngine): void {
    const ability = this;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new BasicMessageChannel<ArrayBuffer>(
      messenger, 'venera/ai_super_resolution_bin', BinaryCodec.INSTANCE_DIRECT
    );
    channel.setMessageHandler({
      onMessage(message: ArrayBuffer, reply: Reply<ArrayBuffer>) {
        if (message == null || message.byteLength == 0) {
          reply.reply(new ArrayBuffer(0));
          return;
        }
        ability.aiSrQueue = ability.aiSrQueue.then(async () => {
          const out = await ability.aiSuperResolve(message);
          // aiSuperResolve 返回 Uint8Array（覆盖整个底层 ArrayBuffer），
          // 取 .buffer 作为零拷贝回复；失败/空结果回空 buffer，Dart 侧
          // 据此降级为原图。
          reply.reply(out == null ? new ArrayBuffer(0) : out.buffer);
        }).catch((err: Error) => {
          Log.e(TAG, "ai superResolve(bin) failed: " + JSON.stringify(err));
          reply.reply(new ArrayBuffer(0));
        });
      }
    });
    Log.i(TAG, "ai_super_resolution_bin channel registered");
  }

  /**
   * 格式化异常为可读字符串（BusinessError/Error/未知对象都处理）。
   */
  private describeError(e: Error | BusinessError | null | undefined): string {
    if (e == null) {
      return "null";
    }
    const b = e as BusinessError;
    const code = b.code;
    const msg = b.message;
    return "code=" + code + " msg=" + msg + " json=" + JSON.stringify(e);
  }

  /**
   * 执行一次 AI 超分。输入原图字节，输出增强后的 JPEG 字节；失败返回 null。
   * 每个步骤独立 try-catch，错误日志带 STEP 前缀便于定位。
   */
  private async aiSuperResolve(buffer: ArrayBuffer): Promise<Uint8Array | null> {
    // STEP 1: 创建引擎
    if (this.aiSrAnalyzer == null) {
      try {
        Log.i(TAG, "aiSuperResolve STEP=create begin");
        this.aiSrAnalyzer = await imageSuperResolution.ImageSRAnalyzer.create();
        Log.i(TAG, "aiSuperResolve STEP=create ok");
      } catch (e) {
        Log.e(TAG, "aiSuperResolve error STEP=create: " + this.describeError(e));
        return null;
      }
    }

    // STEP 2: 解码输入图
    let pixelMap: image.PixelMap;
    try {
      const source = image.createImageSource(buffer);
      pixelMap = await source.createPixelMap();
      Log.i(TAG, "aiSuperResolve STEP=decode ok size=" +
        pixelMap.getImageInfoSync().size.width + "x" + pixelMap.getImageInfoSync().size.height);
    } catch (e) {
      Log.e(TAG, "aiSuperResolve error STEP=decode: " + this.describeError(e));
      return null;
    }

    // STEP 3: 构造 Request
    // 注意：visionBase.Request 的 NAPI 构造器在部分设备上未导出（Constructor is false），
    // 因此不用 new，改用类型断言 + 对象字面量构造（process 只按字段读取 inputData）。
    let request: visionBase.Request;
    try {
      request = {
        inputData: { pixelMap: pixelMap }
      } as visionBase.Request;
      Log.i(TAG, "aiSuperResolve STEP=newRequest ok");
    } catch (e) {
      Log.e(TAG, "aiSuperResolve error STEP=newRequest: " + this.describeError(e));
      return null;
    }

    // STEP 4: AI 超分推理
    let response: imageSuperResolution.ISPResponse;
    try {
      Log.i(TAG, "aiSuperResolve STEP=process begin");
      response = await this.aiSrAnalyzer.process(request);
      Log.i(TAG, "aiSuperResolve STEP=process ok");
    } catch (e) {
      Log.e(TAG, "aiSuperResolve error STEP=process: " + this.describeError(e));
      return null;
    }

    // STEP 5: 编码为 JPEG
    try {
      const info = response.pixelMap.getImageInfoSync();
      Log.i(TAG, "aiSuperResolve STEP=pack begin size=" +
        info.size.width + "x" + info.size.height +
        " pixelFormat=" + info.pixelFormat);
      // 超分返回的 PixelMap 格式特殊（JPEG 编码器无法直接编码为 SkBitmap，
      // 会报 62980119 Failed to encode the image）。先把像素读出来，
      // 转成标准 RGBA_8888 PixelMap 再打包。
      // srcPixelFormat 必须用真实格式（info.pixelFormat），硬编码 RGBA_8888
      // 会导致像素错乱、JPEG 损坏（解码报 62980116）。
      const bytesNumber = response.pixelMap.getPixelBytesNumber();
      const pixelBuffer = new ArrayBuffer(bytesNumber);
      await response.pixelMap.readPixelsToBuffer(pixelBuffer);
      const stdPixelMap = await image.createPixelMapFromPixels(pixelBuffer, {
        size: { width: info.size.width, height: info.size.height },
        srcPixelFormat: info.pixelFormat,
        pixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const packer = image.createImagePacker();
      const option: image.PackingOption = {
        format: 'image/jpeg',
        quality: 80,
        bufferSize: 100 * 1024 * 1024
      };
      const outBuffer = await packer.packing(stdPixelMap, option);
      Log.i(TAG, "aiSuperResolve STEP=pack ok bytes=" + outBuffer.byteLength);
      return new Uint8Array(outBuffer);
    } catch (e) {
      Log.e(TAG, "aiSuperResolve error STEP=pack: " + this.describeError(e));
      return null;
    }
  }

  /**
   * 注册 venera/continuation channel，实现鸿蒙"应用接续"（跨设备流转）能力。
   *
   * 设计：Flutter 阅读器在翻页/切章时通过 updateContinueState 主动上报当前
   * 阅读位置到鸿蒙侧缓存（continueState）；系统在源设备触发接续时调用
   * onContinue，鸿蒙侧直接读缓存写入 wantParam，无需等待引擎通信，避免时序竞态。
   * 目标设备启动后，Flutter 侧通过 getPendingContinueState 拉取接续数据并恢复阅读。
   *
   * 方法：
   * - updateContinueState：入参 { state: string }（阅读位置 JSON），更新源设备缓存。
   * - getPendingContinueState：无入参，返回目标设备待恢复的阅读位置 JSON 或 null。
   */
  private registerContinuation(flutterEngine: FlutterEngine): void {
    const ability = this;
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'venera/continuation');
    // 保存 channel 引用，供热启动接续时主动向 Dart 侧推送状态
    this.continuationChannel = channel;
    channel.setMethodCallHandler({
      onMethodCall(call: MethodCall, result: MethodResult) {
        switch (call.method) {
          case 'updateContinueState': {
            const state: string = call.argument('state');
            if (state != null) {
              ability.continueState = state;
              Log.i(TAG, "continuation updateContinueState: " + state);
            }
            result.success(null);
            break;
          }
          case 'updateContinueActive': {
            const active: boolean = call.argument('active');
            ability.continueActive = active;
            if (active) {
              // 进入阅读器：激活任务接续，任务中心显示流转按钮
              ability.context.setMissionContinueState(AbilityConstant.ContinueState.ACTIVE).catch(
                (err: BusinessError) => {
                  Log.e(TAG, "setMissionContinueState ACTIVE failed: " + JSON.stringify(err));
                });
            } else {
              // 离开阅读器：注销任务接续隐藏流转按钮，并清空缓存，
              // 避免过期的阅读位置被流转
              ability.continueState = null;
              ability.context.setMissionContinueState(AbilityConstant.ContinueState.INACTIVE).catch(
                (err: BusinessError) => {
                  Log.e(TAG, "setMissionContinueState INACTIVE failed: " + JSON.stringify(err));
                });
            }
            Log.i(TAG, "continuation updateContinueActive: " + active);
            result.success(null);
            break;
          }
          case 'getPendingContinueState': {
            Log.i(TAG, "continuation getPendingContinueState: " + ability.pendingContinueState);
            result.success(ability.pendingContinueState);
            break;
          }
          default:
            result.notImplemented();
            break;
        }
      }
    });
    Log.i(TAG, "venera/continuation channel registered");
  }

  /**
   * 注册 venera/smart_grip channel，实现鸿蒙"智感握姿"（握持姿势感知）。
   *
   * 通过 @ohos.multimodalAwareness.motion 监听 holdingHandChanged
   * （握持手变化，since 20，需要 ohos.permission.DETECT_GESTURE），
   * 把 LEFT/RIGHT/BOTH/NOT_HELD 映射为字符串推送给 Dart 侧。Flutter
   * 大屏布局据此把侧边栏切到左/右（右手握持切右侧）。
   *
   * 设备不支持（错误 801）时优雅降级：保持默认左侧布局。
   */
  private registerSmartGrip(flutterEngine: FlutterEngine): void {
    const messenger = flutterEngine.dartExecutor.getBinaryMessenger();
    const channel = new MethodChannel(messenger, 'venera/smart_grip');
    try {
      motion.on('holdingHandChanged', (status: motion.HoldingHandStatus) => {
        let hand = 'unknown';
        switch (status) {
          case motion.HoldingHandStatus.NOT_HELD:
            hand = 'none';
            break;
          case motion.HoldingHandStatus.LEFT_HAND_HELD:
            hand = 'left';
            break;
          case motion.HoldingHandStatus.RIGHT_HAND_HELD:
            hand = 'right';
            break;
          case motion.HoldingHandStatus.BOTH_HANDS_HELD:
            hand = 'both';
            break;
          default:
            hand = 'unknown';
            break;
        }
        Log.i(TAG, "smart_grip holdingHandChanged: " + hand);
        try {
          channel.invokeMethod('holdingHandChanged', hand);
        } catch (e) {
          Log.e(TAG, "smart_grip push failed: " + JSON.stringify(e));
        }
      });
      Log.i(TAG, "venera/smart_grip holdingHandChanged registered");
    } catch (e) {
      // 801: 设备不支持该能力，或权限/服务异常；保持默认左侧布局
      Log.e(TAG, "smart_grip holdingHandChanged not supported: " + JSON.stringify(e));
    }
  }

  /**
   * 应用接续：源设备侧回调。系统流转当前 UIAbility 到其他设备前调用此方法。
   *
   * 把 Flutter 侧上报并缓存的阅读位置写入 wantParam，返回 AGREE 表示允许接续。
   * 若当前没有阅读状态（continueState 为空），拒绝接续（REJECT）。
   *
   * @param wantParam 接续数据容器，系统会原样带到目标设备的 want.parameters。
   * @returns AGREE（同意接续）/ REJECT（拒绝接续）
   */
  onContinue(wantParam: Record<string, Object>): AbilityConstant.OnContinueResult {
    // 只在阅读器激活（continueActive）且存在阅读状态时才允许流转。
    // 否则（主页/详情页/阅读器刚打开尚未上报）拒绝接续，系统不显示流转入口。
    if (this.continueActive &&
        this.continueState != null &&
        this.continueState.length > 0) {
      wantParam[EntryAbility.CONTINUE_STATE_KEY] = this.continueState;
      Log.i(TAG, "onContinue AGREE with state: " + this.continueState);
      return AbilityConstant.OnContinueResult.AGREE;
    }
    Log.i(TAG, "onContinue REJECT (not in reader or no continue state)");
    return AbilityConstant.OnContinueResult.REJECT;
  }

  /**
   * 应用接续：目标设备侧冷启动恢复回调。
   *
   * 接续冷启动时系统调用 onCreate -> onWindowStageRestore（替代 onWindowStageCreate），
   * 这里在创建 Flutter 视图前先把待恢复状态暂存，供 Flutter 启动后拉取。
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    this.tryReadPendingContinueState(want);
    super.onCreate(want, launchParam);
    // 启动时默认不在阅读器：先把任务接续设为 INACTIVE，确保任务中心
    // 不显示流转按钮。进入阅读器后 Flutter 侧 updateContinueActive 会
    // 再切换为 ACTIVE。若省略此调用，启动后主页等页面可能仍显示流转入口。
    this.context.setMissionContinueState(AbilityConstant.ContinueState.INACTIVE).catch(
      (err: BusinessError) => {
        Log.e(TAG, "setMissionContinueState INITIAL INACTIVE failed: " + JSON.stringify(err));
      });
  }

  /**
   * 应用接续：目标设备侧热启动恢复回调。
   *
   * 目标设备已在运行（Flutter 引擎已就绪）时，接续通过 onNewWant 进入。
   * 读取接续数据后直接通过 channel 推送给 Flutter 侧恢复。
   */
  onNewWant(want: Want, launchParams: AbilityConstant.LaunchParam): void {
    this.tryReadPendingContinueState(want);
    super.onNewWant(want, launchParams);
    // Flutter 引擎已运行（channel 已注册），主动推送待恢复状态给 Dart 侧。
    if (this.pendingContinueState != null && this.continuationChannel != null) {
      this.pushPendingContinueState();
    }
  }

  /**
   * 应用接续：目标设备侧 WindowStage 恢复回调。
   *
   * 接续冷启动时系统调用此方法替代 onWindowStageCreate。FlutterAbility 基类
   * 未实现该回调，若直接继承会导致 Flutter 视图永不创建（白屏）。这里手动
   * 复用父类的 onWindowStageCreate 完成 Flutter 视图初始化。
   */
  onWindowStageRestore(windowStage: window.WindowStage): void {
    Log.i(TAG, "onWindowStageRestore: pending=" + this.pendingContinueState);
    this.onWindowStageCreate(windowStage);
  }

  /**
   * 从 want.parameters 中读取接续数据（源设备 onContinue 写入的
   * CONTINUE_STATE_KEY），暂存到 pendingContinueState。
   */
  private tryReadPendingContinueState(want: Want): void {
    try {
      const parameters = want?.parameters;
      if (parameters == null) {
        return;
      }
      const state = parameters[EntryAbility.CONTINUE_STATE_KEY];
      if (typeof state === 'string' && state.length > 0) {
        this.pendingContinueState = state;
        Log.i(TAG, "continuation pending state received: " + state);
      }
    } catch (e) {
      Log.e(TAG, "tryReadPendingContinueState failed: " + JSON.stringify(e));
    }
  }

  /**
   * 主动把待恢复状态推送给 Flutter 侧（热启动接续场景）。
   * 通过 venera/continuation channel 调用 Dart 侧 restorePending 方法。
   *
   * 推送采用 fire-and-forget 方式（不带 callback，与 WebviewPage 的事件
   * 回传一致）：热启动时 Flutter 引擎已运行，channel handler 必然已注册。
   * 若推送失败，冷启动路径（Flutter 主动 getPendingContinueState 查询）不受影响。
   */
  private pushPendingContinueState(): void {
    try {
      const channel = this.continuationChannel;
      const state = this.pendingContinueState;
      if (channel == null || state == null) {
        return;
      }
      channel.invokeMethod('restorePending', state);
      Log.i(TAG, "continuation restorePending pushed");
      this.pendingContinueState = null;
    } catch (e) {
      Log.e(TAG, "pushPendingContinueState failed: " + JSON.stringify(e));
    }
  }
}
