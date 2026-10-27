# ODict for Mac

原生 macOS 菜单栏词典，支持 MDX/MDD 本地词典、在线查词、选中/悬停/截图取词，以及自带服务配置的 AI 查词与翻译。

## 功能

- 手动查词、候选联想、键盘选择、中英文释义和系统英语朗读。
- 直接读取原始 MDX/MDD；不转换词库、不生成中间数据库。支持外置 CSS/JS 调整词典展示。
- 选中取词读取辅助功能接口；悬停取词可选择修饰键，必要时使用局部截图与本机 Vision OCR；截图取词支持框选。取词流程不模拟复制、不读写剪贴板。
- 词典和 AI 使用独立输入草稿，切换模式不自动发送 AI 请求。AI 支持兼容 Chat Completions 的服务、流式 Markdown 和本机 Ollama。
- 手动查询与取词结果分别使用独立窗口。取词窗口的图钉用于固定位置；手动窗口提供输入、模式选择和候选列表。
- 词典历史及结果缓存默认 20 条，可设为 0–100；AI 本机历史默认 20 条，可设为 1–100，支持查看与清空。
- 自定义全局快捷键，默认不占用快捷键。应用位于菜单栏，不显示 Dock 图标。

完整交互以当前版本为准。历史界面截图见 [设计资料](docs/design/)，可能与当前布局不同。

## 系统与开发环境

- 运行系统：macOS 12 Monterey 或更新；Intel 与 Apple Silicon。
- 开发环境：Xcode 26+、Swift 6.2+。应用源码使用 Swift 5 语言模式；固定依赖 KeyboardShortcuts 3.1.0 要求 Swift 6.2。
- 使用 SwiftUI / AppKit；本地词典正文用 WKWebView 渲染。新系统专用 API 有可用性判断及旧系统回退，实际兼容性需在对应系统验证。
- 关闭 App Sandbox 以支持跨应用取词，保留 Hardened Runtime。

## 自行编译与安装

1. 获取源码，复制 `Config/Signing.local.example.xcconfig` 为 `Config/Signing.local.xcconfig`，填写自己的 Apple Developer Team ID。本机文件已被 Git 忽略。
2. 用 Xcode 打开 `ODict.xcodeproj`，等待固定版本依赖解析，选择 `ODict` scheme / `My Mac`，确保自己的 Apple Development 证书可用。
3. 用 Xcode 运行，或在仓库根目录构建 Release 双架构版本：

   ```sh
   sh scripts/build-release.sh
   ```

4. 产物位于 `build/Build/Products/Release/ODict.app`。安装或替换前完全退出旧版本，将应用放入 `/Applications` 后从固定位置启动。

也可仅为这次脚本构建指定团队：

```sh
DEVELOPMENT_TEAM=YOURTEAMID sh scripts/build-release.sh
```

详细的配置优先级、依赖解析、签名和发行流程见 [构建说明](docs/building.md)。本地开发签名产物不等同于已公证的公众发行包。

## 快速开始

首次启动会打开设置。可以按需配置本地词典、在线词典或 AI，三者不要求同时配置。

### 本地词典

在“词典来源”中添加自己合法持有的 MDX 或词典文件夹，检查 MDD 资源关联和启用顺序。支持 MDX/MDD 2.0、未压缩或 zlib 数据块；LZO 等格式限制见 [本地词典说明](docs/local-dictionaries.md)。本仓库不附带词库。

当前词典模式是“本地优先，在线兜底”或“仅使用在线词典”，没有独立的“仅本地”开关。本地命中无需账号；本地未命中、无候选或中文反查可能进入在线路径，在线查询要求登录。“本地优先”不表示禁止联网；关闭启动统计与停止在线查询是两个独立选项。

### 在线词典

在设置的账号区域点击登录，通过系统认证窗口完成网页邮箱注册/登录或 Google 登录，再授权返回客户端。访问与刷新凭证保存在 Keychain，按需自动续期，无需填写产品 API Key。默认 API 地址为 `https://odict.touchany.com/api/`，网页为 `https://odict.touchany.com`；默认配置不代表服务可用性或使用配额承诺。[客户端 API 契约](docs/product-api.md) 包含请求与授权约定。

自行构建可按 [构建说明](docs/building.md#debug-本地登录) 使用 Debug 登录配置连接兼容服务；Release 使用内置入口。不要把管理密钥或公共共享密钥打包进客户端。开源客户端不包含后端服务或词库的使用授权。

### AI 查词与翻译

在 AI 设置填写兼容 Chat Completions 的基础地址或完整 `/chat/completions` 地址、模型和自己的密钥。支持 HTTPS，以及本机 HTTP 回环地址。验证连接会发送示例请求，可能产生费用；验证后仍需保存配置。

输入后显式提交：回车发送，Shift + Enter 换行。停止、关闭窗口或切换相关配置会取消当前请求。正常结果和已有内容的中断结果可写入本机 AI 历史；在 AI 窗口查看或清空。

### 屏幕取词

在设置中按需启用并录制快捷键。选中取词需要辅助功能权限；截图和悬停 OCR 需要屏幕录制权限。拒绝权限不影响手动输入。截图只在本机识别，但识别出的文本会按当前模式发送给所配置服务。权限恢复、支持范围见 [使用与排障](docs/usage.md)。

## 关于与开发者信息

设置侧栏底部的“关于”展示应用版本、开发者 oKing、联系邮箱，以及[项目源码](https://github.com/ooking/odict-macos)、[问题反馈](https://github.com/ooking/odict-macos/issues)和本地许可声明。联系信息与链接集中在 `ODict/Features/Settings/AboutSettingsView.swift` 的 `AppAboutInformation` 中维护。

## 隐私与安全

登录凭证、安装签名私钥和 AI 密钥保存在 Keychain。启动统计默认开启，可在“权限与隐私”关闭；设备 ID 在本机由硬件 UUID 派生，用于按设备去重，登录后关联最近账号。关闭统计后仍可登录关联，但停止启动统计。设置、最近记录和本地词典路径保存在本机；AI 原文及回答以 JSON 文件保存在应用支持目录。截图仅在内存用于 OCR。Debug 诊断可能包含查询词、路径和本地词典 HTML，分享前须脱敏。

详细数据流、保存位置及清理方式见 [PRIVACY.md](PRIVACY.md)。漏洞报告见 [SECURITY.md](SECURITY.md)。

## 开发与贡献

- [贡献指南](CONTRIBUTING.md)：结构、兼容性、资源约束与协作流程。
- [检查与验证](docs/testing.md)：各脚本范围、外部依赖及权限边界。
- [构建与发行](docs/building.md)：本机签名、双架构构建和正式发行。
- [架构检查记录](docs/architecture-review.md)、[OCR 兼容记录](docs/ocr-compatibility.md)、[HoverLookupKit](Packages/HoverLookupKit/README.md)。这些记录中的验证结论只适用于对应时间与范围。
- [历史开发记录](docs/development-history.md)：旧 README 中的排障与迭代记录，不作为当前验收结果。

编译、模拟逻辑检查、实际界面/权限/跨应用验证与内存测量分别报告；编译成功不代表其余验证通过。

## 许可证与署名

项目自有代码和文档采用 [MIT License](LICENSE)，允许商业使用、修改和再分发；复制或分发全部或实质部分时，必须保留版权声明和许可声明。MIT 不要求在应用界面展示作者名称或强制提供回链；欢迎在项目说明中标注 ODict 来源。

第三方依赖、词典内容、截图中的第三方内容和商标按各自授权处理，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。
