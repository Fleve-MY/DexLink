<p align="center">
  <img src="assets/brand/dexlink.png" width="100" alt="DexLink">
</p>

# DexLink

**用 Windows 键鼠操作 Android 手机，并把手机应用放进桌面工作区。**

**简体中文** · [English](README.en.md)

[![Release](https://img.shields.io/github/v/release/Fleve-MY/DexLink?include_prereleases)](https://github.com/Fleve-MY/DexLink/releases)
[![License](https://img.shields.io/github/license/Fleve-MY/DexLink)](LICENSE)
[![Source checks](https://github.com/Fleve-MY/DexLink/actions/workflows/ci.yml/badge.svg)](https://github.com/Fleve-MY/DexLink/actions/workflows/ci.yml)

DexLink 由 Android 手机端和 Windows 客户端组成，通过局域网或 USB 网络共享连接。手机负责运行应用和编码画面，电脑负责原生视频显示、键鼠输入和桌面窗口管理。

当前版本为 **0.1.0 预览版**。主要真机验证环境为小米 15 Pro / Android 17，其他系统与机型的适配情况欢迎通过 Issue 反馈。

## 下载与开始使用

前往 [Releases](https://github.com/Fleve-MY/DexLink/releases) 下载：

- **Windows x64**：`DexLink-win64.zip`。完整解压后运行 `DexLink-win64/dex_pc.exe`，保留同目录的 DLL、`data` 和 `support`。
- **Android**：`DexLink-phone.apk`，要求 Android 8.0 或更新版本。
- **校验文件**：`SHA256SUMS.txt`，用于核对下载文件。

1. 在手机安装并打开 DexLink。
2. 普通镜像：同意系统录屏提示，按引导开启无障碍以使用键鼠控制。
3. 增强镜像或独立桌面：先启动 Shizuku 兼容管理器，并在手机上授权 DexLink。
4. 让手机与电脑连接到同一可信局域网，或开启手机的 USB 网络共享。
5. 打开 Windows 客户端，选择自动发现的手机并连接。

电脑连接页也提供 **USB 安装手机应用**：开启手机 USB 调试并允许当前电脑后，选择设备安装内置 APK。Android 17 的当前内置方案为 Shizuku + Nightzuku。安装后仍需在手机启动管理器并授权。

## 功能

| 功能 | 说明 |
| --- | --- |
| 屏幕镜像 | 显示手机屏幕，支持鼠标、滚轮和文字输入 |
| 增强控制 | 通过 shell 权限实时注入鼠标和键盘事件 |
| 独立桌面 | 应用搜索、Dock、快捷方式、任务切换，以及应用窗口的移动、缩放、最小化与恢复 |
| 原生视频 | Media Foundation / D3D11 解码与 Flutter 纹理呈现，提供软件解码和兼容回退 |
| 文件传输 | 浏览共享目录，上传与下载文件 |
| 文字和附件输入 | 从电脑粘贴文字；可选输入辅助支持向兼容编辑器提交图片和文件 |
| 手机音频 | 增强会话支持系统音频回传与静音 |
| 本地小组件 | 时钟、日历、便签与待办，数据保存在电脑 |

桌面中的应用内容来自手机实时视频，每个受管理应用使用独立副屏。应用窗口位于 DexLink 主窗口内。

## 使用边界

- **连接安全**：当前面向可信局域网。局域网桥接入口尚待完善设备配对与统一授权，视频传输未加密。请保持端口在可信网络内，避免公网映射。
- **无线稳定性**：部分 Wi-Fi 场景仍出现秒级停顿，受网络环境与恢复过程影响。
- **系统兼容**：增强模式依赖 shell 权限、ROM 和应用的副屏适配。受保护内容受 Android 采集限制。
- **附件输入**：需在手机选择可选的 DexLink 输入辅助，目标编辑器需支持对应附件类型。分享和发送由用户在目标应用完成。
- **音频**：普通录屏模式暂未提供音频回传，精确音画同步仍待完善。
- **预览签名**：当前 Android 包使用开发签名。后续正式签名变化时，安装更新可能需要重新安装应用。

## 从源码构建

开发环境：Flutter **3.47.5** / Dart **3.13.4**、JDK 17、Android SDK。Windows 构建还需要 Visual Studio 2022 的 C++ 桌面开发工具和 Windows SDK。

先在仓库根目录执行：

```powershell
flutter pub get --directory app_phone
flutter pub get --directory app_pc
dart pub get --directory packages/dex_link
```

构建 Android：

```powershell
cd app_phone
flutter build apk --release --no-tree-shake-icons
cd ..
```

构建 Windows 前，准备离线 USB 安装资源。下载 [Shizuku 13.6.0](https://github.com/RikkaApps/Shizuku/releases/tag/v13.6.0) 和 [Nightzuku 13.7.1-r60](https://github.com/kerneldroid/Nightzuku/releases/tag/v13.7.1-r60) 的正式 APK，然后执行：

```powershell
python tools/prepare_usb_bundle.py --sdk "C:/path/to/Android/Sdk" --shizuku "C:/downloads/shizuku.apk" --nightzuku "C:/downloads/nightzuku.apk"
cd app_pc
flutter build windows --release --no-tree-shake-icons
cd ..
```

准备脚本检查包名、签名与包体，生成 `app_pc/bundled`。APK、ADB 和构建输出保留在本地，发布到 GitHub Release。

输出路径：

- 手机：`app_phone/build/app/outputs/flutter-apk/app-release.apk`
- 电脑：`app_pc/build/windows/x64/runner/Release/`，分发时需要完整目录

如需生成带许可证和校验文件的发布包：

```powershell
python tools/package_release.py
```

## 源码结构

```text
app_phone/          Android UI、采集、权限、输入与文件服务
app_pc/             Windows UI、桌面工作区、原生视频与音频
packages/dex_link/  两端共享的 Dart 协议
assets/brand/       DexLink 品牌资源
tools/              离线安装资源准备与发布打包
third_party/        第三方许可证与来源声明
```

## 反馈与许可

通过 [Issues](https://github.com/Fleve-MY/DexLink/issues) 反馈问题或提出功能建议，附上软件版本、系统版本、手机型号、连接方式和复现步骤。日志分享前请删除个人内容与设备信息。

安全问题请使用 [私密漏洞报告](https://github.com/Fleve-MY/DexLink/security/advisories/new)。

DexLink 源码使用 [Apache License 2.0](LICENSE)，第三方组件沿用各自协议，见 [第三方声明](THIRD_PARTY_NOTICES.md)。
