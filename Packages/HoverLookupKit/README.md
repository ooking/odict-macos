# HoverLookupKit

可独立引入的原生 macOS 12+ Swift Package，无第三方依赖。提供修饰键悬停检测、辅助功能单词读取、局部截图和本地 Vision OCR；不包含词典查询、网络请求、设置持久化或窗口 UI。

## 接入其他项目

将整个 `HoverLookupKit` 文件夹复制到项目中，在 Xcode 中添加本地 Package，再链接同名 product。宿主负责配置辅助功能、屏幕录制权限和相应隐私说明，以及应用的签名/分发策略。模块不会弹授权框、修改系统设置或调用剪贴板。

在主线程长期持有一个 `HoverLookupMonitor`，通过闭包连接宿主：

```swift
import HoverLookupKit

@MainActor
final class LookupIntegration {
    private let monitor = HoverLookupMonitor()

    init() {
        monitor.canBegin = { /* 当前是否允许自动取词 */ true }
        monitor.containsPanel = { point in /* 是否位于宿主结果窗口 */ false }
        monitor.onResult = { hit in
            // hit.text 是单词；hit.anchor 是全局 AppKit 坐标（点）。
            // 在这里查询词典并展示非激活窗口。
        }
        monitor.onFailure = { error, anchor in /* 宿主提供本地化提示 */ }
        monitor.onDismiss = { /* 隐藏悬停窗口并取消宿主的查询 */ }
        monitor.onInteraction = { /* 用户点击结果窗口时，可让窗口接受焦点 */ }
    }

    func enable() { monitor.setEnabled(true, modifier: .control) }
    func suspend() { monitor.cancel() }
    func stop() { monitor.stop() }
}
```

首次启用、权限变化或宿主重新激活时调用 `setEnabled`。已有监听不会重复注册。用户输入、切换应用/空间、锁屏、进入设置或其他功能时，由宿主调用 `cancel`；退出或停用时调用 `stop`。模块释放时也会注销监听、取消任务。闭包引用宿主时使用弱引用，避免宿主与 monitor 互相持有。

若只需要底层取词，可直接使用 `HoverLookupPipeline.word(in:at:allowsOCR:)`，不启用全局监听。可注入 `HoverTextReading`、`ScreenImageCapturing` 和 `HoverWordRecognizing` 三类 provider。并发调用的取消/旧结果隔离由调用方负责，默认 monitor 已提供单任务与 revision 保护。

## 结构

- `HoverLookupMonitor`：事件监听、300 ms 停稳、防抖、取消、结果有效性、450 ms 收起宽限。
- `HoverLookupPipeline`：辅助功能 → 截图 → OCR；按需创建识别服务，提供类型化错误与分阶段诊断。
- `AccessibilityWordReader`：命中元素及至多八层节点的安全检查；整数范围、按行范围和 Text Marker 能力回退；不读取整个文档或遍历完整节点树。
- `ScreenImageService`：macOS 14+ 单次 ScreenCaptureKit 截图，macOS 12–13 CoreGraphics 回退，最长边不超过 4096 像素。
- `ScreenTextService`：Vision 队列与取消；当前执行失败时仅尝试一次兼容 CPU 策略；单词范围/重复词保持独立坐标。手动截图也可复用其段落识别接口。
- `HoverWords` / `HoverStability`：分词、坐标与命中、等待/提取两阶段移动规则。

## 行为与边界

等待时移动容差默认 3 点，提取中为 12 点；返回后鼠标还必须在实际单词矩形内（水平容差 1 点、垂直 2 点），不能仅凭距离展示旧单词。更大的移动会取消并重新等待，避免快速扫过时反复做 OCR。

安全检查与文字提取分别有 140/240 ms 预算，AX 单次消息最长 40 ms（首次命中最长 80 ms）。安全检查完成后才进行文字提取，父节点不会消耗文字提取的预算。密码、安全输入、自己应用的窗口以及无法确定安全状态的节点禁止 OCR。安全检查通过后，文字接口不支持/读取超时可转 OCR。复杂节点层级无法在上限内确认安全时保持安静，不猜测；这仍需在具体应用中验证兼容性。

Text Marker 通过参数化 AX 属性按能力探测，未链接私有构造函数；目标应用不支持时自然回退。不能保证所有浏览器、Electron 应用或自绘界面都提供这些属性。模块不会开启其他应用的增强辅助功能模式，也不会模拟复制或改变文字选择。

截图仅限鼠标附近最多 640×160 点，单词最多 255 字符/AX UTF-16 单位；整数范围上下文最多 512 UTF-16 单位。无屏幕流、全屏图片缓存、后台轮询或文件落盘。取消会立即释放等待中的工作负载；已开始的系统调用只能协作取消。隐藏/停用会释放模块持有的 OCR 服务，系统内部模型缓存由系统管理，实际进程内存需另测。

`onDiagnostic` 仅包含固定的阶段/结果枚举与耗时，不含文字、截图、坐标、窗口标题、应用名或原始错误。空白/未命中、安全阻断与取消保持静默；真正的截图、OCR 执行失败和缺少 OCR 权限通过 `onFailure` 交给宿主展示。

## 验证

`Tests/HoverLookupKitTests` 覆盖两阶段移动与最终命中、重复词、AX 成功跳过 OCR、安全阻断、权限、回退、按需创建/释放和取消后的旧结果。通过 `swift test --package-path Packages/HoverLookupKit` 执行。仓库原有 `scripts/check-hover.sh` / `scripts/check-capture.sh` 已接入本地模块，保留合成 OCR、坐标与截图流程检查。

测试、真实跨应用操作和内存测量需遵守宿主项目的批准流程。编译成功不代表实际取词已通过验证。

## 设计参考

实现保持独立编写，参考接口行为与模块划分，不引入这些项目作为依赖：

- SelectedTextKit 的 [Text Marker 选区兼容处理](https://github.com/tisfeng/SelectedTextKit/blob/main/Sources/SelectedTextKit/Accessibility/AXManager.swift)。该项目主要读取已选文本，不等同于直接悬停取词。
- WebKit 的 [参数化 Accessibility 接口](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/accessibility/mac/WebAccessibilityObjectWrapperMac.mm)。
- yomiko 的 [OCR 单词命中区域及坐标转换](https://github.com/jrgmadrid/yomiko/blob/main/src/main/ocr/hover-zones.ts)。

