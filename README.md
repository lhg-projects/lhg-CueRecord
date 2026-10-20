# lhg-CueRecord · macOS 录屏提词器

> [!TIP]
> **TL;DR**：macOS 原生录屏 App，一个软件全包高清录屏 + 摄像头画中画 + 麦克风 / 系统音频 + 内置提词器 + 4K 导出，专为录教程、录课、产品演示和口播视频打造。基于 [nolangz/CueRecord](https://github.com/nolangz/CueRecord) v2.0.4（Apache License 2.0）二次开发，后续在此基础上做 lhg 自己的功能。

[![Platform](https://img.shields.io/badge/Platform-macOS-111111)]()
[![Swift](https://img.shields.io/badge/Swift-FA7343?logo=swift&logoColor=white)](https://www.swift.org/)
[![License](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

录一条像样的教程视频，通常要拼三件工具：录屏软件录画面、提词器 App 照着稿子念、摄像头小窗单独开——录完还要对轨、合成，来回折腾。**lhg-CueRecord 把这四件事装进一个原生 macOS App**：选好录制区域、打开提词器照着念，屏幕、摄像头、麦克风和系统声音一次录全，直接导出成片。

**适合谁**：录网课 / 教程的知识创作者、做产品演示和 SaaS walkthrough 的开发者与创始人、录口播和演示稿的演讲者——所有「要对着稿子录屏」的人。

## 核心功能

| 功能 | 说明 |
|---|---|
| 🎬 高清录屏 | 原生 Swift 实现，全屏 / 窗口 / 自选区域录制，支持多显示器（含外接屏） |
| 🪟 摄像头画中画 | 可选摄像头 overlay，预览窗可拖动，和屏幕内容一次合成 |
| 🎙️ 双路音频 | 麦克风 + 系统音频同时录制，最终成片为单轨混合音频，不用后期对轨 |
| 📜 内置提词器 | 可调行数、跟读滚动；录的时候照着念，不用背稿、不用另开提词器 |
| 🤖 AI 气口断句 | 接 OpenAI 兼容模型，自动给提词稿加自然断句（AI Breath Cuts） |
| 📊 PPT 稿导入 | PowerPoint / PPTX 演讲者备注一键导入为提词稿 |
| 🖥️ 4K 导出 | 导出分辨率预设最高 4K，选之前就显示预期输出尺寸 |
| 🗂️ 素材归档 | 原始素材统一收在项目目录的 `raw_data/`，成片留在项目根目录，不丢不乱 |
| 🗣️ 本地语音识别 | 内置本地 ASR 模型资产（Git LFS 管理），语音引导提词不依赖云端 |

## 快速开始

### 源码构建

本仓库用 Git LFS 管理内置模型和原生库，先装 Git LFS 再拉代码：

```bash
git lfs install
git clone https://github.com/lhg-projects/lhg-CueRecord.git
cd lhg-CueRecord
git lfs pull
```

构建本地调试版：

```bash
xcodebuild \
  -project CueRecord.xcodeproj \
  -scheme CueRecord \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

跑录制核心的专项检查：

```bash
scripts/run-recording-core-tests.sh
```

### 预编译包

本仓库暂不提供签名安装包。上游提供已签名并公证的 v2.0.4 DMG，可在 [nolangz/CueRecord Releases](https://github.com/nolangz/CueRecord/releases) 下载；本仓库与上游 v2.0.4 代码一致，装上游包等于先体验同一版本。

## 系统要求

- macOS 14.1 或更高
- Apple Silicon 或 Intel Mac

## 权限说明

录制时按需申请 macOS 标准隐私权限，可在「系统设置 → 隐私与安全性」里管理：

- **屏幕录制**：录制所选显示器 / 窗口 / 区域，必须
- **麦克风**：录人声或使用语音引导提词时需要
- **摄像头**：开启摄像头画中画时需要
- **系统音频**：开启系统音频录制时需要

## 发布构建

`build.sh` 生成通用（Universal）App、签名、打包 DMG 并提交 Apple 公证。签名身份走环境变量，换成你自己的 Developer ID 即可：

```bash
TEAM_ID=<你的 Team ID>
SIGN_IDENTITY='Developer ID Application: <你的名字> (<Team ID>)'
NOTARY_PROFILE=<你的 notarytool keychain profile>
./build.sh
```

产物输出到 `build/release/CueRecord.dmg`。前置条件：Xcode 命令行工具、本机 Keychain 里装好 Developer ID 证书、Git LFS 资产已拉全。

## 项目结构

```text
CueRecord/                App 源码
CueRecord/Recording/      录制管线、界面、区域选择、指标、导出组织
Tests/RecordingCoreTests/ 录制核心行为的命令行专项检查
Vendor/                   Git LFS 管理的原生库与本地 ASR 模型资产
build.sh                  签名 + 公证的发布 DMG 构建脚本
```

## 与上游的关系

- 本项目 fork 自 [nolangz/CueRecord](https://github.com/nolangz/CueRecord) v2.0.4，依 **Apache License 2.0** 二次开发；许可证原文见 [LICENSE](LICENSE)，上游版权声明保留。
- 其中**提词器部分源自 [f/textream](https://github.com/f/textream)**（上游 Credits 已注明，此处沿袭标注）。
- 本次整改范围：README 与项目元信息已按 lhg-projects 自有项目规范重写，去掉上游作者的个人品牌内容；**代码与上游 v2.0.4 保持一致**，后续功能迭代在本仓库进行。
- 这是一个已发布的成熟项目，改动遵循上游 `AGENTS.md` 的约定：改动保持小而聚焦，每处改动测试受影响的区域后再算完成。
