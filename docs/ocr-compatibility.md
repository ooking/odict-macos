# E5 文字识别诊断与按请求回退

2026-10-20。用户报告悬停无结果或明显卡住，并出现 `TextRecognition.framework` 的 `GetE5PathFromCompositeBundle` 错误，目标为系统 `cr_td_model_v3_e5.mlmodelc.bundle`。该日志涉及系统模型加载，但本身不能证明模型损坏、某个 macOS 代际存在普遍问题，或此次悬停失败的完整原因。用户随后补充同一系统此前一直可用、后来突然失效；据此撤销按 macOS 27 强制降级的策略。

## 本机证据

- 系统为 macOS 27.0.1（26A434）。只读查看上述目录可见通用模型数据，未见日志列出的硬件子包；应用不读取或依赖此私有路径，也没有修改系统文件。
- 经用户同意，使用内存生成的图片运行原生 Vision。默认路径一次在 25 秒外部期限内未完成；单独 GPU 路径一次约 24.4 秒。CPU 对英文模型的一次处理约 0.13 秒，但这不足以证明中英文均正常。
- 补测中文时，独立探针启用自动语言检测后在 CPU 上抛出了 `TextRecognition.CRImageReaderError.e5rtError`。正式服务没有启用此选项，因此该探针错误不能直接证明正式服务在相同位置失败。
- Vision 修订版 2 + CPU 能识别生成的中英文图像。首次切换模型仍观察到约 5.2 秒初始化，不能承诺冷启动零等待；后续回归覆盖正式 `ScreenTextService`，不以独立探针代替正式实现。

上述耗时来自不同运行阶段的小样本，受系统模型初始化和缓存影响，不是性能基准或长期上限。没有读取用户屏幕、权限、偏好、钥匙串或真实查询数据。

## 实现

`ScreenTextService` 中的 `OCRComputePolicy` 集中管理请求修订版、语言及计算设备：

1. 所有系统首先使用 Vision 默认修订版和默认设备选择，不读取系统版本决定是否降级。
2. 仅当识别请求实际报错时，对当前请求尝试一次系统支持的 Vision 修订版 2 + CPU 路径，使用前检查 `supportedRevisions` 和 `supportedComputeStageDevices`。后续请求仍从默认调度开始，不把暂时性故障变成该服务实例的持续降级，不缓存图片或请求。
3. 优先简繁中文和英文，维持 accurate 模式，避免中文被优先的英文模型误读成拉丁字母。没有启用此次探针中出错的自动语言检测。
4. 取消时不回退；空识别、悬停空白或文字范围匹配失败不重试。原有串行队列、Vision 取消、过期结果保护、255 字及截图尺寸限制保留。
5. macOS 14+ 通过公开的计算设备 API 配置 CPU；12–13 回退到该系统支持的 `usesCPUOnly`。兼容修订版不增加第三方 OCR 或附加模型，不使用私有 API。

修订版 2 是 Apple 已标记弃用、但当前仍支持的实现，此处仅作为单次识别异常后的兼容路径保留；需随系统更新复查其可用性。

此前根据本机 27.0.1 的小样本试验对整个 macOS 27 主动降级，证据不足且会影响正常系统，现已移除。默认请求若只是长时间不返回而未抛错，不会触发当前回退；不能宣称这项调整已解决所有卡住情形。发生真实故障时还需区分 AX 读取、截图、OCR 执行、鼠标移动/任务取消及查词请求，才能确定根因。

## 验证

`sh scripts/check-hover.sh` 已更新为检查默认请求不更改系统修订版或设备选择，同时保留兼容修订版、各阶段实际 CPU 指派、英文/中文/混合图片识别、重复单词定位、点号分隔、空白不命中与取消。`sh scripts/check-capture.sh` 覆盖取词协调的取消、权限拒绝、坐标及晚到结果。

早先强制兼容版本的两组检查曾通过，其中一次生成图片 OCR 回归约 0.52 秒（系统模型已初始化，不能代表冷启动）。该结果不适用于本次恢复默认调度的版本。本次用户要求只修改并编译，未运行调整后的测试或进行界面验证；Release 构建状态由本次交付报告说明。

本次未启动正式应用进行真实屏幕悬停/截图验证，也未测试 macOS 12–13 或 Intel 运行时。编译使用项目的 Release 双架构构建脚本和 Apple Development 签名，不覆盖为临时签名。

公开接口参考：[Apple Vision 识别与修订版](https://developer.apple.com/documentation/vision/recognizing-text-in-images)、[指定计算设备](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:))。

## 应用编译缓存缺失的实际恢复

用户随后提供了更具体的日志：`~/Library/Caches/com.touchany.odict.mac/com.apple.e5rt.e5bundlecache/.../H15S.bundle/main/main_ane/model.anehash` 缺失，E5RT Code 13。只读检查确认目标目录为空，整个 ODict E5 缓存为 0 字节。这能确认应用缓存资源缺失，但尚未确认是如何变空的，不能据此认定某个系统版本普遍损坏。

经用户授权，退出正在运行的 Xcode Debug 副本，仅删除上述 ODict 专属 E5 编译缓存，保留词典、设置和 Keychain，随后启动当前开发签名的 Release。未修改识别策略或自动清理逻辑，不自动删除其他应用、系统模型或共享 CoreML 缓存。

使用正式 `ScreenTextService` 和 `HoverWordChecks` 构造临时诊断包，以相同 `com.touchany.odict.mac` 标识及 Apple Development 签名运行，避免仅验证另一个命令行程序自己的缓存。生成图片检查覆盖默认策略、兼容配置、中英文/混合识别、重复词定位、点号两侧命中、空白和取消，连续两次通过：首次约 20.96 秒，第二次约 0.83 秒。ODict E5 缓存重建后有 4 个文件、约 65 KB，其中 2 个 `model.anehash`，此前缺失的缓存资源已恢复。该小样本仅说明此次缓存恢复及 OCR 回归结果，不是长期性能或不再复发的保证。

Release 双架构构建及开发签名校验通过。真实悬停界面验证已尝试，但自动操作工具连续收到系统 ScreenCaptureKit `-3811`（audio/video capture failure），未能完成；不得把本地 OCR 检查记为真实界面通过。尚未诊断该独立捕获错误与最初悬停失效之间是否有关。
