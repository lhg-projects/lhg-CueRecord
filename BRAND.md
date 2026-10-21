# 品牌规范：刘老师 · 录课台

本文件是本项目的品牌唯一事实源。改图标、改配色、改文案之前先读这里。

## 名字

| 位置 | 值 |
|---|---|
| 显示名（Dock / Finder / 菜单栏 / 关于页） | `刘老师 · 录课台` |
| 产物名（`.app` 文件名、可执行文件） | `LLSStudio` |
| 仓库 | `lls-projects/lls-studio` |
| Bundle ID | `com.liulaoshi.llsstudio` |
| 组织 | `lls-projects`（刘老师产品仓） |

称呼规则：句子中间提到时用「录课台」，标题、Dock、关于页用全称「刘老师 · 录课台」。

## 图标

图形由四个元素组成，各自对应一个真实功能，不许随意增删：

| 元素 | 含义 |
|---|---|
| 圆角方底（石墨黑渐变） | App 载体，工具感、不抢眼 |
| 白色卡片 + 三行横条 | 课件画面 / 提词稿 |
| 圆形人像窗（白描边 + 投影） | 出镜小窗里的「你」 |
| 红色圆点 | 正在录制 |

配色（石墨黑）：

| 用途 | 值 |
|---|---|
| 底色渐变 | `#282C36` → `#0D0F14` |
| 左上暖光 | `#FF7A5C`，透明度峰值 ~40% |
| 卡片 / 横条 | `#FFFFFF`，次要横条 `#14161E` @46% |
| 出镜窗底 | `#181A22`，人像 `#F0F2F8` |
| 录制红点 | `#FF453A` |

技术约定：1024 主图，图形内容坐在 824×824 网格内（macOS 圆角方底标准），超椭圆 n=5；切图覆盖 16/32/128/256/512 的 1x/2x。生成脚本不入库，改图时重新出全套，不要只改某一个尺寸。

## 文案

- 说「你」，不说「用户」；说「录一条」，不说「执行录制任务」。
- 功能描述先给动作再给结果：「打开提词器照着念，录完直接出成片」。
- 不堆形容词，不写「强大」「一站式」「全方位」这类词。
- 中文标点，中英文之间留空格。

## 不许改的标识

这些串留在原地，是为了让老用户的 Vault、已存 API Key、已有成片继续能用。改名会直接让数据失联：

- `.cuerecord` 元数据目录、`.cuerecord` / `takeone` / `cueshot` 文档扩展名
- UTI `com.nolanlai.cuerecord.document`、`cuerecord://` URL scheme
- Keychain service：`com.nolanlai.cuerecord.ai-provider`、`com.nolanlai.cuerecord.deepseek`
- DispatchQueue 标签、Swift 类型名（`CueRecord*`）

## 上游归属

本项目是 [nolangz/CueRecord](https://github.com/nolangz/CueRecord) v2.0.4 的二次开发（Apache-2.0）。所有对外文案、关于页、NOTICE 必须保留上游署名；改动文件需带修改声明（见 [NOTICE](NOTICE)）。
