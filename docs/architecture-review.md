# 原生客户端流程检查与模块化重构

日期：2026-10-20。目标是保留当前界面和功能，收窄职责、修复可确认的问题，并为取消、资源上限及系统兼容性建立可替换的边界。未引入新的第三方依赖。

## 检查结论与修改

| 问题 | 实施后的处理 |
| --- | --- |
| 应用委托同时负责菜单栏、两类窗口、热键、前台来源与取词，生命周期相互影响 | 委托只转发系统生命周期；`ApplicationCoordinator` 连接功能模块，窗口控制器各自拥有窗口和临时监听器 |
| API 客户端作为自己持有的 URLSession 的 delegate，形成持有环；可并发调用的 lazy session 不适合作为共享状态 | `HTTPTransport` 持有独立 delegate 和不可变 session；delegate 不引用 transport，释放 transport 时取消 session |
| 更换服务时，独立读取地址、读取或保存密钥可能配错目标 | `ServiceSettingsStore` 提供地址/密钥快照，Keychain 串行队列同时提交对应地址；请求只使用同一快照 |
| 同步系统调用取消后，调用方仍可能等待系统返回 | `BlockingWorkQueue` 在取消时立即恢复调用方，跳过尚未执行的任务；已开始的系统调用允许完成，不能假装强行终止 Keychain |
| 设置窗口隐藏后仍保留输入的密钥和异步状态 | 独立 `SettingsModel`，关闭时清除 UI 密钥引用并撤销任务；窗口及模型释放，晚到回调不回填；打开时重新加载 |
| 下载完整响应后才判断，没有响应体累积上限 | HTTP delegate 检查 Content-Length 和实际收到的分块；应用累积的单次响应体最多 4 MiB；15 秒请求、20 秒资源超时，无磁盘缓存、Cookie 或共享凭据存储，不跟随重定向 |
| 429 只展示提示，连续输入仍可能请求相同服务 | 独立 `RequestRateLimit` 解析秒数及 HTTP-date，以单调时钟执行本机冷却；只保存一个服务来源，无轮询、自动重试或无限字典 |
| 输入法组合文字会进入候选查询 | 原生 `CandidateSearchField` 将 marked-text 状态交给模型，组合中取消请求，提交后才防抖查询；方向键/回车继续交给输入法 |
| 候选数据和旧偏好可能包含空项、重复项或越界项 | 候选单次遍历过滤并最多保留 10 项，最近记录最多 20 项；提取 `RecentWordsStore`，可注入独立偏好域 |
| 朗读、最近记录混入查询状态模型 | 原生语音拆为按需创建的 `PronunciationService`；关闭面板停止并释放合成器 |
| 截图、OCR、框选难以独立模拟，切换应用通知可能中断预期的焦点返回 | 取词服务通过小协议注入，协调器有明确阶段；前台来源由应用协调器统一处理并过滤过期通知；保留任务标识与取消保护 |
| 旧系统原始截图可能先分配过大的 Retina 图像 | macOS 12–13 按选区面积选择原生或逻辑分辨率，限制原始区域像素量，随后限制最长边 4096；14+ 截图配置直接限制尺寸并排除本应用窗口 |
| 旧容器偏好文件可能过大 | 迁移只读取最多 256 KiB 的属性列表，继续使用白名单、不覆盖新设置、不迁移密钥 |

先前启动卡顿已有两份独立证据：同步 Keychain 曾阻塞主线程；随后首击日志显示事件已经到达，但窗口受激活/自动隐藏影响反复收起。本次保留已修复的非激活面板、`hidesOnDeactivate = false`、点击菜单栏按钮不当作外部点击等行为。正常查词窗口不请求激活整个应用，设置窗口仍按普通窗口激活。

## 模块边界

```text
ODictApp / AppDelegate
  └─ ApplicationCoordinator                生命周期、热键、前台来源、功能连接
       ├─ MenuBarController                NSStatusItem、按钮位置/状态
       ├─ LookupWindowController           非激活面板、定位、临时鼠标监听
       │    └─ LookupView / CandidateSearchField
       │         └─ LookupModel            候选/释义状态、防抖、取消、旧结果保护
       │              ├─ DictionaryServing → DictionaryClient
       │              │    ├─ ServiceSettingsServing → ServiceSettingsStore → KeychainStore
       │              │    ├─ HTTPTransporting → HTTPTransport
       │              │    └─ RequestRateLimit
       │              ├─ RecentWordsStore
       │              └─ PronunciationService
       ├─ SettingsWindowController → SettingsView / SettingsModel
       │    └─ ServiceSettingsServing
       └─ CaptureCoordinator               单次任务、阶段、权限失败、结果出口
            ├─ SelectedTextReading         有限范围 Accessibility 读取
            ├─ ScreenRegionSelecting       临时原生框选窗口
            ├─ ScreenImageCapturing        单次系统截图与旧系统回退
            └─ ScreenTextRecognizing       本机 Vision 串行识别
```

只为确实需要替换系统边界的依赖定义协议，避免为每个辅助类型增加工厂、全局服务容器或新的状态框架。视图不直接读写 Keychain 或发网络请求。

## 生命周期与数据约束

- UI 和协调器由 MainActor 管理；Keychain/Accessibility 使用串行后台队列，OCR 使用独立串行队列，网络分块由串行 delegate 队列处理。
- 修改搜索、关闭面板、开始另一次取词或退出会取消相关任务。无法立即停止的系统操作通过取消标志及请求标识丢弃晚到结果，不覆盖新状态。
- 关闭面板移除临时鼠标监听、取消取词/OCR、停止朗读；框选完成或取消即关闭并释放遮罩。退出移除快捷键处理器、工作区通知与菜单栏项。
- 截图不落盘、上传或记日志；OCR 完成只把文字交给查词。输入最多 255 字，截图最长边 4096，API 响应累积最多 4 MiB，最近记录 20 条，候选 10 项。
- 本地窗口诊断降为 debug 级别，只记录生命周期和耗时元数据，不记录词、密钥或图像。没有常驻截图、OCR、重试计时器或轮询。
- Bundle ID、Keychain service/account、已存快捷键及 UserDefaults 键保留；继续直接分发，保持 Hardened Runtime。

## 验证范围

当前重构通过 Release 双架构编译（arm64、x86_64）。本地回归脚本：

- `scripts/check-lookup.sh`：候选预览、键盘导航与防抖、复用进行中的请求、中文/近似查询、输入法状态、去重/上限、错误和关闭清理、过期响应丢弃。使用临时偏好域。
- `scripts/check-capture.sh`：文本和 255 字边界、多屏坐标、定位边界、迁移白名单、权限拒绝、重复取词与取消；完整截图管线使用生成的 1 像素图像和延迟 OCR 替身，不访问屏幕或 Vision。
- `scripts/check-runtime.sh`：系统工作队列取消、跳过已取消任务、服务快照、URL 编码、HTTP 响应上限与取消、transport 释放、Retry-After、最近记录和关闭设置后的晚到结果。使用 URLProtocol 模拟响应，不联网或访问真实钥匙串。

测试须按仓库约定先说明方案并得到同意。本次本地替身回归已获同意；运行结果和最终签名状态见 README 中本次记录。

编译与替身结果不能证明实际 UI、系统权限、Keychain 授权、识别质量或进程内存水平。仍需另行同意后验证：正式程序启动首击、菜单与输入法、两种取词、连续取消与外部切换；真实 Keychain 设置读写；Retina/多屏/全屏；反复取词的内存快照。macOS 12–13、Intel 与不同 Space 行为需对应设备验证。尚未测得本次重构的内存或速度改善数值。

## 维护约定

新功能按上述边界扩展；系统操作先有可取消/可丢弃结果的路径，再接入 UI。不要把窗口展示、截图权限或 Keychain 调用重新放回查词视图。修改窗口时保留原生面板的焦点约定，不能为了收起行为重新加入全局激活或常驻监听。网络/系统边界尽量使用本地替身验证，实际权限与兼容性验证独立记录。
