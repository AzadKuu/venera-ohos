<p align="center">
  <img src="assets/app_icon.png" width="120" alt="venera-ohos">
</p>

<h1 align="center">venera-ohos</h1>

<p align="center">
  漫画阅读器 <a href="https://github.com/venera-app/venera">venera</a> 的鸿蒙（HarmonyOS）适配版<br>
  端侧 AI 超分 · 应用接续 · 智感握姿
</p>

<p align="center">
  <a href="https://flutter.dev/"><img src="https://img.shields.io/badge/Flutter-3.8%2B-blue?logo=flutter"></a>
  <a href="https://www.harmonyos.com/"><img src="https://img.shields.io/badge/HarmonyOS-6.1%2B-0B5ED8?logo=harmonyos"></a>
  <a href="https://github.com/AzadKuu/venera-ohos/releases"><img src="https://img.shields.io/github/v/release/AzadKuu/venera-ohos?include_prereleases&label=release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/AzadKuu/venera-ohos?color=blue"></a>
  <a href="https://github.com/AzadKuu/venera-ohos/stargazers"><img src="https://img.shields.io/github/stars/AzadKuu/venera-ohos?style=flat"></a>
</p>

---

## 简介

本项目是开源漫画阅读器 [venera](https://github.com/venera-app/venera)（上游已停止维护）的 **HarmonyOS 自用适配分支**。在上游多平台能力基础上，接入鸿蒙原生能力，提供端侧 AI 超分辨率、跨设备应用接续、智感握姿等增强体验。

> **⚠️ 注意**
>
> 这是鸿蒙适配版的自用项目，可能会随时做激进更改，使用请慎重。
>
> 如果你从[原项目](https://github.com/venera-app/venera)迁移过来，**WebDAV 同步目录请使用新的目录，不要和原项目共用同一目录**，否则可能导致数据异常。

## 功能特性

### 📚 基础能力（继承自上游）

| 能力 | 说明 |
| --- | --- |
| 本地漫画 | 读取本地压缩包/文件夹中的漫画 |
| 网络漫画源 | 使用 JavaScript 编写漫画源，从网络源阅读 |
| 收藏管理 | 收藏漫画、分组管理、追更 |
| 下载 | 离线下载漫画章节 |
| 元信息 | 查看评论、标签等（取决于源支持） |
| 账号 | 登录后评论、评分等（取决于源支持） |
| WebDAV 同步 | 跨设备数据同步 |
| 多平台 | Android / iOS / Windows / macOS / Linux / **HarmonyOS** |

### ✨ 鸿蒙增强

- **🤖 端侧 AI 超分** — 通过 `@hms.ai.vision.imageSuperResolution`（Core Vision Kit）对阅读图片做端侧超分辨率增强，无需联网、不传云端。仅在鸿蒙设备可用，其它平台自动降级为原图。
  - `lib/foundation/ai_super_resolution.dart` · channel `venera/ai_super_resolution`
- **🔄 应用接续** — 基于鸿蒙流转能力，把"正在阅读的漫画 + 章节 + 页码"从源设备流转到目标设备继续阅读。仅在漫画阅读页启用，避免主页等页面误显示接续入口。
  - `lib/foundation/continuation.dart` · channel `venera/continuation`
- **✋ 智感握姿** — 通过 `@ohos.multimodalAwareness.motion` 监听握持手变化，大屏（折叠屏/平板）下检测到右手握持时自动把侧边栏切到右侧，方便单手操作。
  - `lib/foundation/smart_grip.dart` · channel `venera/smart_grip`
- **🧩 原生依赖适配** — 对 `flutter_qjs` / `sqlite3` / `zip_flutter` / `lodepng_flutter` 做本地修改，增加 ohos 平台分支以加载随 HAP 打包的 `.so` 动态库（见 `third_party/` 与 `pubspec.yaml` 的 `dependency_overrides`）。
- **🌐 WebView 桥接** — 鸿蒙侧 `WebviewBridge` 对接 Flutter 的 `flutter_inappwebview`，用于漫画源登录等场景。

## 安装

### 从 Release 下载

从 [GitHub Releases](https://github.com/AzadKuu/venera-ohos/releases) 下载最新 HAP 包：

- `venera-ohos-unsign.hap` — 未签名包，需自行[签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-signing)后通过 DevEco Studio 或 `hdc install` 安装。

> 当前为预发布版本（prerelease），ohos 适配仍在迭代中。

### 从源码构建

**环境要求**

- [Flutter](https://flutter.dev/) 3.8+（鸿蒙需使用 [ohos-flutter](https://gitcode.com/openharmony-sig/flutter_flutter) 分支）
- [HarmonyOS SDK](https://developer.huawei.com/consumer/cn/doc/harmonyos-downloads) 6.1+ / DevEco Studio
- [Rust](https://rustup.rs/)（部分原生依赖构建用）
- Git

**步骤**

```bash
# 1. 克隆
git clone https://github.com/AzadKuu/venera-ohos.git
cd venera-ohos

# 2. 拉取依赖
flutter pub get

# 3. 生成 ohos 平台代码（首次）
flutter create --platforms=ohos .

# 4. 构建 HAP（在 ohos/ 目录用 DevEco Studio 或 hvigor）
#    产物：ohos/entry/build/default/outputs/default/entry-default-signed.hap
```

构建产物位于 `ohos/entry/build/default/outputs/default/`：

| 文件 | 说明 |
| --- | --- |
| `entry-default-signed.hap` | 已签名包（需配置本地签名材料） |
| `entry-default-unsigned.hap` | 未签名包 |

签名配置见 `ohos/build-profile.json5` 的 `signingConfigs`。

## 项目结构

```
venera-ohos/
├─ lib/                    # Flutter Dart 代码
│  └─ foundation/
│     ├─ ai_super_resolution.dart   # AI 超分封装
│     ├─ continuation.dart          # 应用接续封装
│     ├─ smart_grip.dart            # 智感握姿封装
│     └─ ohos_compat.dart           # 鸿蒙平台兼容层
├─ ohos/                   # HarmonyOS 原生工程
│  └─ entry/src/main/ets/
│     ├─ entryability/EntryAbility.ets   # 鸿蒙侧 channel 注册
│     └─ webview/WebviewBridge.ets       # WebView 桥接
├─ third_party/            # 本地修改版原生依赖
│  ├─ flutter_qjs/  sqlite3/  zip_flutter/  lodepng_flutter/
├─ assets/                 # 资源（图标、翻译、JS 漫画源运行时）
├─ doc/                    # 文档
└─ pubspec.yaml            # 依赖与 dependency_overrides
```

## 文档

| 文档 | 说明 |
| --- | --- |
| [漫画源开发](doc/comic_source.md) | 如何用 JavaScript 编写自定义漫画源 |
| [JS API](doc/js_api.md) | 漫画源 JS 运行时 API 参考 |
| [Headless 模式](doc/headless_doc.md) | 无界面运行模式 |
| [导入漫画](doc/import_comic.md) | 本地漫画导入说明 |

## 致谢

- **上游项目**：[venera-app/venera](https://github.com/venera-app/venera) — 漫画阅读器本体
- **标签翻译**：[EhTagTranslation/Database](https://github.com/EhTagTranslation/Database) — 漫画标签中文翻译
- **鸿蒙 Flutter**：[openharmony-sig](https://gitcode.com/openharmony-sig) — Flutter 鸿蒙适配

## 许可证

[GPL-3.0](LICENSE)，继承自上游 venera 项目。
