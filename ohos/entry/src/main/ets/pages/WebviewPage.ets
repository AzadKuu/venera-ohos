import web_webview from '@ohos.web.webview';
import { WebviewBridge } from '../webview/WebviewBridge';
import { Log } from '@ohos/flutter_ohos';

const TAG = "WebviewPage";

/**
 * 全屏 Web 组件页面，用于漫画源登录。
 *
 * 由 EntryAbility 的 venera/webview channel handler 在收到 open(url) 时，
 * 通过子窗口 loadContent('pages/WebviewPage') 拉起。URL 从 WebviewBridge.currentUrl 取。
 *
 * 事件通过 WebviewBridge.channel 回传 Dart 侧：
 * - onLoadIntercept → onNavigation(url)
 * - onTitleReceive → onTitleChange(title)
 */
@Entry
@Component
struct WebviewPage {
  controller: web_webview.WebviewController = new web_webview.WebviewController();
  @State url: string = WebviewBridge.currentUrl;

  aboutToAppear() {
    WebviewBridge.controller = this.controller;
    Log.i(TAG, "aboutToAppear url=" + this.url);
  }

  build() {
    Column() {
      Web({ src: this.url, controller: this.controller })
        .width('100%')
        .height('100%')
        .onTitleReceive((event) => {
          Log.i(TAG, "title: " + event.title);
          const ch = WebviewBridge.channel;
          if (ch != null) {
            ch.invokeMethod('onTitleChange', event.title);
          }
        })
        .onLoadIntercept((event) => {
          if (event.data.isMainFrame()) {
            const navUrl = event.data.getRequestUrl();
            Log.i(TAG, "nav: " + navUrl);
            WebviewBridge.currentUrl = navUrl;
            const ch = WebviewBridge.channel;
            if (ch != null) {
              ch.invokeMethod('onNavigation', navUrl);
            }
          }
          return false;
        })
        .onPageEnd((event) => {
          Log.i(TAG, "pageEnd: " + event.url);
          const ch = WebviewBridge.channel;
          if (ch != null) {
            ch.invokeMethod('onPageEnd', event.url);
            // 在 Web 组件所在子窗口上下文取 cookie 回传。
            // 同时试 origin 和完整 url，应对 fetchCookieSync 的 domain 匹配差异。
            try {
              const u = event.url;
              const schemeEnd = u.indexOf('://');
              let origin = u;
              if (schemeEnd >= 0) {
                const pathStart = u.indexOf('/', schemeEnd + 3);
                origin = pathStart >= 0 ? u.substring(0, pathStart) : u;
              }
              const ck1 = web_webview.WebCookieManager.fetchCookieSync(origin);
              const ck2 = web_webview.WebCookieManager.fetchCookieSync(u);
              const ck = ck1.length >= ck2.length ? ck1 : ck2;
              Log.i(TAG, "onPageEnd cookies origin.len=" + ck1.length + " full.len=" + ck2.length);
              // 决定性诊断：configCookieSync 写测试 cookie再读回，验证 API 是否工作。
              // 如果 testRead 包含 testcookie，说明 API 工作但子窗口 cookie 没进全局 store。
              // 如果 testRead 空，说明 API 本身不工作（arkweb core level 0）。
              try {
                web_webview.WebCookieManager.configCookieSync(origin, "testcookie=testvalue");
                const testRead = web_webview.WebCookieManager.fetchCookieSync(origin);
                Log.i(TAG, "DIAG configCookie+fetch testRead=" + testRead);
              } catch (e2) {
                Log.e(TAG, "DIAG configCookieSync failed: " + JSON.stringify(e2));
              }
              // 诊断：incognito 模式
              const ckIncog = web_webview.WebCookieManager.fetchCookieSync(origin, true);
              Log.i(TAG, "DIAG incognito=true len=" + ckIncog.length + " val=" + ckIncog.substring(0, 100));
              // 诊断：打印完整 cookie 值（截断 200）
              Log.i(TAG, "DIAG origin cookie full=" + ck1.substring(0, 200));
              Log.i(TAG, "DIAG fullurl cookie full=" + ck2.substring(0, 200));
              ch.invokeMethod('onCookies', ck);
            } catch (e) {
              Log.e(TAG, "onPageEnd fetchCookie failed: " + JSON.stringify(e));
            }
          }
        })
        .onErrorReceive((event) => {
          Log.e(TAG, "web error: " + event.error.getErrorInfo());
        })
    }
  }
}
