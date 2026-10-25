# 本地词典摘要与覆盖样式

设置里的「词典管理」为每本词典单独保存「使用覆盖样式」，旧配置默认开启。
开关只控制该词典的 `odict-overrides.css`（包括内置默认覆盖 CSS），不改变原始 CSS、JS、MDX/MDD 或 `odict-overrides.js`。
修改开关会沿用词典配置变更通知，取消旧查询、清空结果缓存并刷新当前可见结果。

## 摘要顺序

在线词典继续使用 API 的结构化 translation；本地词典按以下顺序取第一个有效中文摘要：

1. HTML 的 `<meta name="odict-summary" content="中文释义">` 或带 `data-odict-summary` 的元素文本。
2. 词典目录中的 `odict-summary.json` 提供的有序 XPath 规则。
3. 现有牛津 8、朗文、必应兼容规则及通用中文翻译标记。
4. 标有 def、def-g、definition 的元素或 class、`itemprop="definition"` 的文本。

第 1 项是可选的输入协议，不要求修改任何现有词典。没有可靠语义标记时返回空摘要，避免把导航或任意中文例句当成释义。
牛津 9 的 `<def><chn>…</chn></def>` 通过通用自定义标签保留机制处理，无需按词典名称或路径分支。
解析前移除例句、习语/短语区、隐藏节点、脚本等子树；清理空白、控制字符和零宽字符，去重后最多保留 2 条、240 字符。
这不是万能自然语言识别：不规范标记、通过 CSS 隐藏的内容、脚本生成的释义或新型例句结构可能需要外部规则。

## 外部规则示例

在需要适配的词典目录新建 `odict-summary.json`：

```json
{
  "version": 1,
  "definitionPaths": [
    "//*[@class='my-definition']/*[@lang='zh']",
    "//*[@data-odict-tag='meaning']/*[@data-odict-tag='cn']"
  ],
  "excludedPaths": ["//*[@class='my-example']"]
}
```

规则只作用于临时 DOM，不改写原始词条。HTML tidy 不认识的自定义标签会先转换为保留同名 `data-odict-tag` 属性的 span；例如 `<chn>` 对应 `//*[@data-odict-tag='chn']`。标准 HTML 标签仍可直接选择。
`definitionPaths` 按顺序回退；`excludedPaths` 可省略。优先选择叶子级中文释义，避免选择整篇文章。
无效 JSON、版本或 XPath 不阻断查词，继续内置回退。文件最大 64 KiB，每类规则最多 16 条、每条最多 2048 字节；禁止通过符号链接逃离词典目录。
修改后点击词典管理中的「重新加载样式与摘要规则」，再查词，使缓存中的旧摘要失效。

## 缓存和资源边界

摘要在本地词典后台 actor 中随词条生成，复用现有查询结果 LRU（默认 20、最高 100 项，另有 8 MiB 负载上限）和最近查词摘要持久化，不另建常驻 DOM、WebKit 或无限缓存。
临时 DOM 输入上限 512 KiB、每次最多检查前 128 个候选；禁止加载外部实体，不执行脚本、不请求网络。
规则按需读取，不保留文件句柄；隐藏时沿用原有渲染器和词典资源释放路径。没有进行实际内存测量。
旧历史摘要不会批量重写；重新查询某个词后更新该词的摘要。

牛津 9 样式副本见 `local-dictionary-styles/oxford-advanced-learner-dictionary-9.css`，实际使用的是词典目录内的 `odict-overrides.css`。仅维护覆盖 CSS，原始词典内容保持不变。
