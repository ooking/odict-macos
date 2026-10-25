# 构建、签名与发行

## 开发环境

使用 Xcode 26+（包含 Swift 6.2+）及 macOS SDK；项目最低部署目标为 macOS 12。默认工具链目录为 `/Applications/Xcode.app/Contents/Developer`，安装在其他位置时通过 `DEVELOPER_DIR` 指定。远程依赖版本和提交由 `Package.resolved` 固定，不需要本机安装其他包管理器。

## 本机签名配置

```sh
cp Config/Signing.local.example.xcconfig Config/Signing.local.xcconfig
```

将本机文件中的 `YOURTEAMID` 替换为自己的 Apple Developer Team ID，并确保钥匙串中有该团队的 Apple Development 证书及对应私钥。证书、私钥和 API 密钥都不应放入配置文件。

- `Config/Signing.xcconfig` 是应用 Debug/Release 共用的基础配置，仓库中不保存个人 Team。
- 它可选包含同目录的 `Signing.local.xcconfig`；后者已被 `.gitignore` 排除。
- Xcode 打开项目也会读取该配置，无须修改 `project.pbxproj`。建议在本机配置中维护 Team；不要再在 Signing & Capabilities 中写入个人团队并提交项目文件。
- Release 脚本通过 `-xcconfig` 将配置同时传给应用和 Swift Package target，避免它们使用不同团队。
- 脚本的环境变量 `DEVELOPMENT_TEAM` 优先于本机配置，仅作用于这次构建。未提供环境变量且没有本机文件时，脚本会提示配置后停止。空值、示例 Team 或不可用证书会导致 Xcode 构建失败，不会跳过签名。

```sh
DEVELOPMENT_TEAM=YOURTEAMID sh scripts/build-release.sh
```

本机现有 Team 在迁移时保存在忽略文件中；公共配置没有个人团队 ID。仓库历史中已有的配置不会因本次迁移自动消失。

## 依赖与构建

首次打开项目时等待 Xcode 获取固定依赖。也可以显式解析锁定版本：

```sh
xcodebuild -resolvePackageDependencies -project ODict.xcodeproj -scheme ODict -derivedDataPath build -onlyUsePackageVersionsFromResolvedFile
sh scripts/build-release.sh
```

Release 脚本沿用锁定依赖，不自动升级版本。构建指定 `arm64 x86_64`、`ONLY_ACTIVE_ARCH=NO`，始终使用 Apple Development 签名。不得通过关闭签名或构建后覆盖为临时签名解决错误。

产物为 `build/Build/Products/Release/ODict.app`。`LICENSE` 和 `THIRD_PARTY_NOTICES.md` 随应用放入 `Contents/Resources/`。版本号在项目中维护；Build 号由构建阶段使用北京时间 `yyyyMMddHHmm` 生成，同一分钟构建编号相同。

构建脚本只构建，不启动应用、不安装、不运行测试，也不申请屏幕或辅助功能权限。

## 安装与更新

完全退出旧进程，再将产物放到 `/Applications/ODict.app`。保持应用位置、Team、Bundle ID 和签名类型稳定，有助于系统识别同一应用；权限是否保留需在实际系统验证。更换签名身份时，系统可能要求重新授权辅助功能、屏幕录制或 Keychain。

项目默认 Bundle ID 为 `com.touchany.odict.mac`。发布独立 fork 时应使用自己的标识，并审查代码中的 Keychain service、UserDefaults 迁移和 AIHistory 目录：它们有固定命名，单独修改 Bundle ID 不能保证数据与原版完全隔离。不要迁移或覆盖用户现有数据而不提供说明。

## 公众安装包

Apple Development 产物用于本机开发。公开提供直接下载安装包时，另建 Developer ID Application 签名、公证及装订票据的发行流程；不要更改开发脚本的签名身份来混用两种用途。参考 [Apple Developer ID](https://developer.apple.com/developer-id/) 与 [公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

发行流程应包含：在受保护的发布环境使用证书、双架构构建、Developer ID 签名、公证与装订、打包、SHA-256 校验值和对应版本说明。证书私钥及公证凭据只进入本机 Keychain 或发布系统的受保护凭据存储，不提交仓库或输出到日志。

发布前单独验证最低支持系统、两种架构、首次安装、升级后权限和 Keychain 行为。当前仓库的开发构建脚本不执行这些发行步骤。
