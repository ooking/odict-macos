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

## GitHub 预览版上传（暂不公证）

`scripts/upload-release.sh` 用于将现有 Apple Development 开发签名产物上传到固定仓库 `ooking/odict-macos`，并直接公开发布为 **Pre-release**。它不编译、不修改签名、不公证，也不提交代码或创建、推送标签。开发签名在其他电脑上的实际运行、权限和 Keychain 行为仍需单独验证。

先安装 GitHub CLI，并以有仓库发布权限的账号登录：

```sh
brew install gh
gh auth login --hostname github.com
```

让 `gh` 管理登录凭据；不要将令牌、证书私钥或密码写入脚本或仓库。若仓库私有，发布预览版也不会让未获授权的人下载；公开下载需要公开仓库。

确认已有 Release 产物来自待发布代码，且应用版本号正确。脚本读取 **产物** 的版本与 Build 号，不读取当前源码版本，也无法证明旧产物对应哪个提交。尤其在有未提交修改时，应自行确认待发布源码、产物和标签一致。需要重新编译时，单独运行原有构建脚本。

在确认正确的提交后，准备并推送标签，例如应用版本为 `1.0.1` 时：

```sh
git tag -a v1.0.1 <待发布提交的完整SHA> -m 'ODict 1.0.1 preview'
git push origin refs/tags/v1.0.1
```

将示例中的提交占位符替换成真实提交；标签已存在时不要重复创建或强制移动。然后执行：

```sh
sh scripts/upload-release.sh v1.0.1
```

脚本检查 GitHub 登录、远程标签、重复 Release、应用标识与必要资源、开发签名完整性及 arm64/x86_64 双架构。版本不匹配或任何检查失败都会停止。它会对产物创建临时副本，以同一副本完成检查和打包，结束后删除临时副本。

输出位于 `build/releases/v1.0.1/`：

- `ODict-1.0.1-macOS-universal.zip`：完整应用包。
- `ODict-1.0.1-macOS-universal.zip.sha256`：SHA-256 校验文件。
- `release-notes.md`：包含 Build 号、系统要求、安装及首次手动放行说明的发布说明。

脚本先创建草稿，两个附件上传成功后才发布预览版，不将其标记为 Latest。它不会覆盖远程同标签的任何 Release 或附件；重复运行可以重新生成本地文件，但远程 Release 存在时会提前停止。

### 上传失败后的恢复

网络失败可能发生在 GitHub 已完成操作之后。先查看仓库 Releases，确认实际状态，避免重复发布。脚本不会自动删除草稿、附件或标签，本地完整下载包与发布说明会保留。

- 若已有完整的公开预览版，无需重复操作。
- 若有草稿，在网页检查是否已有 ZIP 和校验文件；缺少哪个就补传哪个，再确认发布说明并发布为预览版。
- 若附件不完整或错误，只在草稿页面删除错误附件，再上传保留的本地文件。不要混用不同打包批次的 ZIP 和校验文件。
- 若想从头重试，确认是失败留下的草稿后，在网页删除该草稿、保留原版本标签，再重新运行脚本。不要删除已公开的 Release 来绕过重复检查。
- 若没有任何 Release，解决网络或权限问题后重新运行脚本即可。

运行脚本会实际上传并公开发布，不是预演。开发阶段的脚本测试、真实安装验证及内存测量仍须按协作约定事先说明方案并获得同意。

## Debug 本地登录

Debug 构建在「设置 → 关于 → 登录调试」提供登录网页地址、API 地址及登录回调 URL，可保存或恢复线上默认值。Release 不包含该入口，也不读取调试配置。

- 登录网页填站点根地址，例如 `http://localhost:5174`；应用自动进入 `/auth/client`。
- API 默认使用同域反代地址 `https://odict.touchany.com/api/`；本地同域反代填写 `http://localhost:5174/api/`，保留 `/api/` 前缀；该配置也用于在线词典和设备服务。HTTP 仅允许 `localhost`、`127.0.0.1` 和 `::1`，其他主机要求 HTTPS。构建时仅为 Debug 添加本地网络 ATS 配置。
- 回调通常保留 `com.touchany.odict:/auth/callback`。只允许应用已注册的 `com.touchany.odict` 协议，不支持 HTTP 回调或本地回调监听端口。修改路径时，网页和 API 的回调允许配置也必须同步修改；当前网页和 API 默认严格校验上述默认值。
- 保存后重新发起登录。进行中的登录固定使用启动时的地址及回调，授权请求与凭证交换使用同一个回调值。
- 本地网页还需指向本地 API，API 的 `ODICT_WEB_ORIGIN` 需匹配本地网页。应用设置不会修改网页或 API 配置。
- `/api/` 统一入口必须分流到两个后端监听器：Mac 登录、设备接口及 Bearer 查词请求进入客户端监听器，网页账号及匿名查词请求进入网页监听器。本地规则位于相邻 odict-web 的 `scripts/api-proxy.ts`；生产规则位于其 `docs/nginx.conf`，更新静态网页不会自动部署 Nginx 配置。

调试地址保存在本机偏好设置中；登录凭证仍按 API 地址区分并保存在 Keychain。设置不增加后台任务、网络监听或常驻服务。

## 通用账户协议更新

Mac 授权请求显式声明 S256，token/refresh/logout 均发送 client_id=odict-macos。需要配套 API 的 016_auth_clients 迁移及新版网站，不兼容旧客户端请求。数据库 SQL 与发布顺序见相邻 odict-api/docs/auth-clients.md。本轮未编译 Mac，也未执行迁移或部署。
