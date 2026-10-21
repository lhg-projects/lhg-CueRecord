# 交接文档：刘老师 · 录课台（LLSStudio）

写给接手的工程师或 Agent。目标：不用重新摸索，就能定位问题、改代码、验证、打包。

---

## 0. 三十秒了解这个项目

- 这是一个 **macOS 原生录课工具**：屏幕 + 摄像头同时录制，配提词器（悬浮在屏幕顶部），录完能进编辑器手动合成导出。
- 代码来自开源项目 `nolangz/CueRecord`（Apache-2.0）的 fork，已经改成自己的产品身份：中文名「刘老师 · 录课台」，英文/机器名 `LLSStudio`。
- 当前版本 **2.2.1 (build 9)**，57 个 Swift 文件，`Vendor/` 里约 370 MB 语音模型与动态库（走 Git LFS）。
- 用户是课程作者，不是工程师。**交付必须是能双击运行的 `.app` / `.dmg`，不是源码。**

---

## 1. 环境与仓库

| 项 | 值 |
|---|---|
| 工作副本 | `/Volumes/work/code/CueRecord` |
| origin | `https://github.com/lhg-projects/lls-studio.git`（分支 `main`） |
| upstream | `https://github.com/nolangz/CueRecord.git`（只读参考，不要往上推） |
| Xcode | 16.4 (`/Applications/Xcode-16.4.0.app`)，Swift 6.1，部署目标 macOS 14.1 |
| 运行系统 | macOS 15.3.1 (24D70)，Apple Silicon |
| 构建产物 | `build/DerivedData/Build/Products/Release/LLSStudio.app` |
| 安装位置 | `~/Applications/LLSStudio.app`（用户级，不需要 sudo） |
| 冻结来源 | `5f01087` 是 fork 后的第一个提交（上游 v2.0.4 + Xcode 16.4 适配） |

日常命令：

```bash
cd /Volumes/work/code/CueRecord
git lfs install && git lfs pull        # 首次，否则 Vendor 里是几百字节的指针文件
./scripts/run-recording-core-tests.sh  # 22 项核心测试，必须全 PASS
./scripts/build-local.sh               # 只构建
./scripts/build-local.sh --install     # 构建并装到 ~/Applications
```

门禁：**这两条命令不通过，不算改完**。这是仓库 `AGENTS.md` 明文要求的。

---

## 2. 用户是谁，什么算「完成」

- 用户是「刘老师」，做 AI 实操课程，这个软件是他录课的生产工具。
- 他对代码没有耐心，要的是**能用**。所以：改完要自己跑起来验证，再告诉他一句话结论 + 怎么用。
- 他明确讨厌：反复要权限、启动就崩、中英混杂、把简单问题说复杂。
- 交付习惯：桌面放一份 `.dmg`，`~/Applications` 装一份能直接运行的。

---

## 3. 代码地图

### 3.1 录制主链路

| 文件 | 职责 |
|---|---|
| `CueRecord/Recording/RecordingController.swift` | 录制总控：开录/停录、设备刷新、权限请求编排、状态机 |
| `CueRecord/Recording/Core/Recording/ScreenRecorder.swift` | 屏幕与系统音频采集（ScreenCaptureKit），产出 `ScreenRecord_*.mov` |
| `CueRecord/Recording/Core/Camera/CameraManager.swift` | 摄像头采集与热切换，产出 `*_camera.mov` |
| `CueRecord/Recording/Core/Audio/AudioManager.swift` | 麦克风设备与电平 |
| `CueRecord/Recording/Core/Recording/RecordingSync.swift` | 多轨时间对齐（关键：起录门槛在 `AudioStartGate`） |
| `CueRecord/Recording/Core/Recording/RecordingArtifactOrganizer.swift` | 录制产物归档、命名、`raw_data/` 组织 |
| `CueRecord/Recording/Core/Recording/RecordingOutputValidator.swift` | 产物完整性校验（时长、轨道、可解码） |
| `CueRecord/Recording/Core/Recording/RecordingEditorPresentation.swift` | 「录完是否自动弹编辑器」的判定（曾经重复弹窗的元凶） |

**录制模型是「原始多轨 + 手动合成」**：一次录制落盘为屏幕轨、摄像头轨、`_overlay.json`、`_metrics.json`；用户在编辑器里导出时才合成为 `_composited.mov`。不要假设录完就有一个合成好的文件。

### 3.2 提词器与浮窗

| 文件 | 职责 |
|---|---|
| `CueRecord/NotchOverlayController.swift` | 刘海浮窗（`NotchOverlayView`）+ 独立悬浮窗（`FloatingOverlayView`）+ 面板管理 |
| `CueRecord/NotchSettings.swift` | 全部外观设置（宽度、字号、背景模式、跟随鼠标…） |
| `CueRecord/Teleprompter/CueTextTokenizer.swift` | 讲稿分词与换行标记 |
| `CueRecord/Teleprompter/SpeechTrackingMatcher.swift` | 语音与文字的模糊对齐（中英混排） |

浮窗背景三档：`OverlayBackgroundMode` = `solid` / `blur` / `clear`。`clear` 不画底板、不画毛玻璃、不画观众脸背景，只画文字并叠一圈暗影保证浅底可读。

### 3.3 语音与 AI

| 文件 | 职责 |
|---|---|
| `CueRecord/SpeechRecognizer.swift` | SherpaOnnx 流式语音识别，输出 `lastSpokenText`、`shouldDismiss`、`shouldAdvancePage` |
| `CueRecord/AI/ScriptAI.swift` | OpenAI 兼容 chat/completions 客户端、Keychain 密钥存取、AI 断句 |
| `CueRecord/AI/AIModelCatalog.swift` | provider 目录（默认 `deepseek`）、模型选择持久化 |
| `CueRecord/AI/AIVoiceAssistant.swift` | 语音口令：规则层（离线）+ 模型层（DeepSeek）双层解析 |
| `CueRecord/AI/AIScriptComposerSheet.swift` | AI 断句界面 |

语音口令的动作映射在 `NotchOverlayView` 的 `.onChange(of: speechRecognizer.lastSpokenText)` 里：翻页 → `shouldAdvancePage`，结束 → `shouldDismiss`，跳页 → `content.jumpToPageIndex`，暂停/继续 → `isPaused`。

### 3.4 本地化

- `CueRecord/InterfaceLanguage.swift`：`zhHans` 字典（384 条）+ `InterfaceLanguageSettings.shared.text(_:)`。
- 界面文案一律走 `Text(InterfaceLanguageSettings.shared.text("English Source"))`，字面量保持英文做 key。
- 默认语言是**简体中文**（`InterfaceLanguageSettings` 兜底值），不是跟随系统。

### 3.5 构建与打包

| 文件 | 职责 |
|---|---|
| `scripts/build-local.sh` | 本地 Release 构建 + 稳定签名 + 安装到 `~/Applications` |
| `scripts/run-recording-core-tests.sh` | 核心测试编译运行（swiftc 直编，不经 xcodebuild） |
| `build.sh` | 带 Developer ID 签名/公证的正式打包，需要 Apple 开发者账号 |
| `BRAND.md` | 品牌规范：名字、配色、图标四元素、文案规则 |
| `Info.plist` | 文档类型、权限用途说明；注意部分 key 由 `INFOPLIST_KEY_*` 构建设置生成，改 plist 不一定生效 |

---

## 4. 坑位清单（真实踩过，按踩坑频率排序）

### 4.1 权限相关（最耗时间的一类）

**坑 1：adhoc 签名的「代码要求」是自身 cdhash，每次重建都会变。**
后果：macOS 把新包当另一个应用，用户已授权的屏幕录制/摄像头/麦克风全部失效，表现为「我明明开了它还一直要」。
诊断：`codesign -d -r- App.app` —— 如果输出 `designated => cdhash H"xxxx"`，就是这个问题。
已修：`scripts/build-local.sh` 构建后重签，把代码要求固定为 `designated => identifier "com.liulaoshi.llsstudio"`。

**坑 2：`CODE_SIGNING_REQUIRED=NO` 会让 entitlements 根本不写进签名。**
后果：hardened runtime 应用缺 `com.apple.security.device.camera`，系统**连弹窗都不弹**，静默拒绝。
诊断：`codesign -d --entitlements :- App.app` —— 只剩 `get-task-allow` 就是没签进去。
已修：构建脚本改为正常签名，并显式传 `CODE_SIGN_ENTITLEMENTS`、`ENABLE_HARDENED_RUNTIME=YES`；entitlements 里加 `disable-library-validation` 以允许加载 `Vendor/` 下的第三方 dylib。

**坑 3：只查权限不请求权限。**
后果：`AVCaptureDevice.authorizationStatus` 是 `notDetermined` 时，代码只读状态就返回，系统永远不会弹窗，摄像头窗一直黑着。
已修：`CameraManager.checkCameraAvailability()` 在 `notDetermined` 时主动请求一次（带去重标记，避免循环）。

**坑 4：屏幕录制授权只对新启动的进程生效。**
后果：用户在系统设置勾了开关，当前进程仍返回未授权 → 应用再请求 → 再弹窗 → 死循环。
已修：`PermissionsManager` 里 `hasPromptedScreenRecording` 保证每次启动最多弹一次；引导页不再自动弹窗；界面给「重启应用」按钮（`relaunchApplication()`）。

排查权限问题时最有用的一条命令：

```bash
log show --predicate 'process == "tccd"' --last 5m --style compact | grep -i "llsstudio" | tail -20
```

看 `AUTHREQ_PROMPTING`（弹窗了）、`requires entitlement ... but it is missing`（被静默拒绝）、`AUTHREQ_RESULT`（用户选择）。

### 4.2 崩溃类

**坑 5：`zhHans` 字典字面量重复 key → 启动即崩。**
Swift 对字典字面量的重复 key 不在编译期报错，运行时 `SIGTRAP`，堆栈指向 `one-time initialization for zhHans`。
已修 + 加了回归测试 `LocalizationDictionaryHasNoDuplicateKeys`（扫源码文本查重）。**加词条前先跑这条测试。**

**坑 6：`@Observable` / `@Bindable` 属性错位。**
在 `class NotchSettings` 前插入新类型时，容易把 `@Observable` 留在新类型上，报 `'init(wrappedValue:)' is unavailable`。看到这个错，先看属性归属对不对。

### 4.3 构建与工具链

**坑 7：`build-local.sh --install` 先 `rm -rf` 目标再 `ditto` 复制。**
命令在两步之间被打断（超时、Ctrl-C），`~/Applications/LLSStudio.app` 会消失。恢复就是重跑一次构建。

**坑 8：`Vendor/` 是 Git LFS，没 pull 就是指针文件。**
构建脚本会检查 5 个关键资产的文件大小，小于 100 KB 直接报错退出。

**坑 9：`Info.plist` 里的权限说明可能被构建设置覆盖。**
`INFOPLIST_KEY_NSMicrophoneUsageDescription` 等 key 在 `project.pbxproj` 里，改仓库根目录的 `Info.plist` 不一定生效。改完用 `PlistBuddy` 读构建产物确认。

### 4.4 不能改的标识（数据契约）

改了会丢用户数据，收益为零：

| 标识 | 位置 |
|---|---|
| `.cuerecord` 元数据目录 | 工程目录内 |
| `.cuerecord` / `takeone` / `cueshot` 扩展名 | `Info.plist`、代码 |
| UTI `com.nolanlai.cuerecord.document` | `Info.plist` |
| URL scheme `cuerecord://` | `Info.plist` |
| Keychain service `com.nolanlai.cuerecord.ai-provider` / `.deepseek` | `ScriptAI.swift` |
| Swift 类型名 `CueRecord*` | 全项目 |

判断标准：**用户看得见的跟品牌走，用户数据依赖的一个字节都不动。**

---

## 5. 怎么调试（照这个来）

### 5.1 拿到应用自己的日志

应用大量使用 `print()`（关键字：`📷` 摄像头、`📺` 屏幕录制、`🎤` 麦克风、`🔐` 权限、`⚠️` 异常）。这些不会进统一日志系统，必须挂 stdout：

```bash
open --env NSUnbufferedIO=YES --stdout /tmp/app.log --stderr /tmp/app.log ~/Applications/LLSStudio.app
sleep 10 && grep -aE "📷|📺|🔐|⚠️" /tmp/app.log
```

`NSUnbufferedIO=YES` 不能省，否则日志全被缓冲，文件是空的。
直接运行二进制（`~/Applications/LLSStudio.app/Contents/MacOS/LLSStudio`）也能看到日志，但那是**从终端启动**，TCC 会把「responsible process」记到终端或上层应用头上，摄像头/屏幕录制这类权限的表现会和在 Finder 里双击不一致。**验证权限问题必须用 `open` 或双击。**

### 5.2 崩溃

```bash
ls -t ~/Library/Logs/DiagnosticReports/LLSStudio* | head -3
```

读 `.ips`：第一条 JSON 是头部，第二条是正文；找 `exception.type`、`termination`、以及触发线程的 `Swift runtime failure` 那行符号。

### 5.3 权限状态

```bash
tccutil reset Camera com.liulaoshi.llsstudio         # 单项重置
tccutil reset ScreenCapture com.liulaoshi.llsstudio
tccutil reset Microphone com.liulaoshi.llsstudio
```
`~/Library/Application Support/com.apple.TCC/TCC.db` 没有完全磁盘访问权限读不了，别浪费时间。

### 5.4 设置项

偏好文件：`~/Library/Preferences/com.liulaoshi.llsstudio.plist`。

```bash
defaults read com.liulaoshi.llsstudio overlayBackgroundMode
defaults write com.liulaoshi.llsstudio overlayBackgroundMode -string clear
```

---

## 6. 测试

```bash
./scripts/run-recording-core-tests.sh
```

22 项，覆盖：音频起录门槛、录制目标解析、像素格式策略、多轨同步、产物归档与校验、路径策略、工程清单冲突、临时 Vault、Vault 修复、讲稿分词与换行、节奏标记、跨行锚点匹配、编辑器弹出判定、AI 语音口令解析、本地化词条查重。

当前状态：全 PASS。新增功能请同步加测试，测试文件在 `Tests/RecordingCoreTests/main.swift`，脚本里要记得把新源文件加进 `swiftc` 列表。

---

## 7. 已知限制 / 待办

| 项 | 说明 |
|---|---|
| 独立悬浮窗未接语音口令 | 口令接线只在 `NotchOverlayView`（刘海浮窗）；`FloatingOverlayView` 没接 |
| 切换语言不实时刷新 | 走单例读取文案的视图要等重建才更新；设置页本身监听语言变化 |
| DMG 未公证 | 本地 adhoc 签名，用户自己机器能跑；发给别人需要 Developer ID + 公证 |
| 组织改名未做 | `lhg-projects` → `lls-projects` 需要 `admin:org` 权限，命令见 `lls-handbook/decisions/` |
| 语音口令默认关闭 | 设置 → 语音 → 语音口令，用户需手动打开 |
| 旧版 vault 丢失 | 换 Bundle ID 后是独立应用，旧路径 `~/Desktop/练习-第1课` 已不存在 |

---

## 8. 相关文档（都在 GitHub）

| 文档 | 位置 | 内容 |
|---|---|---|
| 品牌规范 | `lls-studio/BRAND.md` | 名字、配色、图标语义、文案规则 |
| 工程约束总纲 | `lls-handbook/README.md` | 命名规则、工程约束、写作约束、交付格式、十条自检 |
| 改名决策记录 | `lls-handbook/decisions/2026-10-21-rename-to-lls-studio.md` | 为什么改名、已完成项、剩余步骤 |
| 变更单 | `lls-handbook/changes/2026-10-21-chinese-default-and-voice-ai.md` | 中文默认、汉化、DeepSeek 接入的具体改法 |

---

## 9. 接手后建议的第一步

1. `git lfs pull`，然后跑一次 `./scripts/run-recording-core-tests.sh` 和 `./scripts/build-local.sh --install`，确认基线是绿的。
2. 用 `open --env NSUnbufferedIO=YES --stdout ...` 启动，录一条 30 秒的测试，看 `_composited.mov` 能不能导出来。这是这个软件的核心价值，坏了其他都白搭。
3. 复现用户报告的问题时，先看 `📷📺🔐` 三类日志，再看 `tccd` 日志，最后才怀疑业务代码——过去两天里，权限与签名问题占了全部故障的七成。
