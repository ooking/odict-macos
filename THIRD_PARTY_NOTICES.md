# 第三方声明

## KeyboardShortcuts 3.1.0

- 来源：https://github.com/sindresorhus/KeyboardShortcuts
- 固定版本及提交见 `ODict.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。
- 许可证：MIT。以下保留该版本的完整版权和许可声明。

```text
MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## 系统组件

SwiftUI、AppKit、WebKit、Vision、ScreenCaptureKit、Security 和系统 zlib 通过系统 SDK 使用；它们不改用本仓库的 MIT 许可证。

## 设计参考

HoverLookupKit 的接口行为及模块划分参考见 [模块说明](Packages/HoverLookupKit/README.md#设计参考)。这些项目不是本仓库的打包依赖；参考链接不代表取得复制其代码的授权。引入或移植第三方代码时，应先核对许可证，并补齐其要求的声明。

## 词典内容与素材

本仓库不提供 MDX/MDD 词库。程序的 MIT 许可证不授予第三方词典正文、音频、字体、图片、商标或外部服务数据的使用权。使用或分发这些内容须遵守各自授权。

`docs/design/` 中的历史界面截图可能包含词典内容；不应把程序的 MIT 许可解释为这些第三方内容的再分发许可。发布宣传素材前应核对内容授权，必要时用自制示例替换。

应用构建会将本文件和根目录 `LICENSE` 复制进应用的 Resources。重新打包或分发时请一并保留；新增依赖时同步更新本文件。
