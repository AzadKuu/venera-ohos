import { MethodChannel } from '@ohos/flutter_ohos';
import web_webview from '@ohos.web.webview';
import window from '@ohos.window';

/**
 * webview 桥接全局单例。
 *
 * EntryAbility 创建 venera/webview MethodChannel 后存到此处，
 * WebviewPage（子窗口的 ArkTS 页面）通过它向 Dart 侧发送 onNavigation/onTitleChange 事件，
 * EntryAbility 的 channel handler 通过 controller 响应 Dart 侧的 getCookies/getLocalStorage。
 */
export class WebviewBridge {
  static channel: MethodChannel | null = null;
  static controller: web_webview.WebviewController | null = null;
  static currentUrl: string = '';
  static subWindow: window.Window | null = null;
}
