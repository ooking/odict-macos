# macOS 27 E5 文字识别兼容处理

2026-10-20。用户报告悬停无结果或明显卡住，并出现 `TextRecognition.framework` 的 `GetE5PathFromCompositeBundle` 错误，目标为系统 `cr_td_model_v3_e5.mlmodelc.bundle`。这是系统文字识别模型加载路径的问题；该日志本身不能证明整个系统模型损坏，也不能证明所有识别都会失败。

## 本机证据

- 系统为 macOS 27.0.1（26A434）。只读查看上述目录可见通用模型数据，未见日志列出的硬件子包；应用不读取或依赖此私有路径，也没有修改系统文件。
- 经用户同意，使用内存生成的图片运行原生 Vision。默认路径一次在 25 秒外部期限内未完成；单独 GPU 路径一次约 24.4 秒。CPU 对英文模型的一次处理约 0.13 秒，但这不足以证明中英文均正常。
- 补测中文时，默认修订版的自动语言检测路径在 CPU 上也抛出了 `TextRecognition.CRImageReaderError.e5rtError`。因此单纯“只用 CPU”不能完整处理该兼容问题。
- Vision 修订版 2 + CPU 能识别生成的中英文图像。首次切换模型仍观察到约 5.2 秒初始化，不能承诺冷启动零等待；后续回归覆盖正式 `ScreenTextService`，不以独立探针代替正式实现。

上述耗时来自不同运行阶段的小样本，受系统模型初始化和缓存影响，不是性能基准或长期上限。没有读取用户屏幕、权限、偏好、钥匙串或真实查询数据。

## 实现

`ScreenTextService` 中的 `OCRComputePolicy` 集中管理请求修订版、语言及计算设备：

1. macOS 27 优先选择系统支持的 Vision 修订版 2，并对请求每个支持的计算阶段指定 CPU，绕开当前有问题的模型/加速组合。使用前检查 `supportedRevisions` 和 `supportedComputeStageDevices`。
2. 其他系统保留默认 Vision 修订版和默认设备选择。若执行失败，最多尝试一次相同的兼容路径；成功后该服务实例只记住后端选择，不缓存图片或请求。
3. 优先简繁中文和英文，维持 accurate 模式，避免中文被优先的英文模型误读成拉丁字母。没有启用此次探针中出错的自动语言检测。
4. 取消时不回退；空识别、悬停空白或文字范围匹配失败不重试。原有串行队列、Vision 取消、过期结果保护、255 字及截图尺寸限制保留。
5. macOS 14+ 通过公开的计算设备 API 配置 CPU；12–13 回退到该系统支持的 `usesCPUOnly`。兼容修订版不增加第三方 OCR 或附加模型，不使用私有 API。

修订版 2 是 Apple 已标记弃用、但当前仍支持的实现，此处有意作为故障兼容路径保留；需在未来系统修复后复查策略，不应无限扩展到新系统代际。

这里按 macOS 27 主动绕过，是基于本机 27.0.1 的复现证据，并非已确认所有 27 版本都异常、或其他版本绝对正常；其他系统同样保留执行失败后的兼容回退。当前策略范围比已验证的具体补丁版本更宽，代价是在尚未出现问题的 27 系统上也使用较早修订版和 CPU，需在后续实机验证后收窄或移除。

## 验证

`sh scripts/check-hover.sh` 使用正式服务检查：macOS 27 策略与其他系统策略的边界、兼容修订版、各阶段实际 CPU 指派、英文/中文/混合图片识别、重复单词定位、空白不命中与取消。`sh scripts/check-capture.sh` 覆盖取词协调的取消、权限拒绝、坐标及晚到结果。

上述两组检查均通过。最终一次 OCR 回归中全部生成图片识别约 0.52 秒（系统模型已初始化，不能代表冷启动）。Release 编译、arm64/x86_64 架构检查及开发签名校验通过；仅余项目不使用 AppIntents 的元数据跳过提示。

本次未启动正式应用进行真实屏幕悬停/截图验证，也未测试 macOS 12–13 或 Intel 运行时。编译使用项目的 Release 双架构构建脚本和 Apple Development 签名，不覆盖为临时签名。

公开接口参考：[Apple Vision 识别与修订版](https://developer.apple.com/documentation/vision/recognizing-text-in-images)、[指定计算设备](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:))。
