# Legado 如何通过书源解析一本书的完整信息

> 研究范围：`gedoor/legado` 官方仓库的一手源码。本文固定引用官方仓库历史提交
> [`ef9b4c28`](https://github.com/gedoor/legado/commit/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad)（2025-11-13），避免后续源码变化导致结论漂移。
> 截至本文撰写时，官方仓库当前 `main` 已只保留公告，因此以下永久链接使用仍可由 GitHub API 访问的历史提交，而不是第三方教程或 fork。
> 研究时通过保留完整历史的 fork 取回该提交对象，并以官方仓库 GitHub Commit API 可返回同一 SHA 验证其确属上游历史；正文引用统一指向 `gedoor/legado` 的该固定提交。

## 结论先行

Legado 的书源不是“一个返回整本书的 API 定义”，而是一份 JSON **解析配置**。完整取书是四段流水线：

```text
searchUrl + ruleSearch
        ↓ SearchBook（候选书）
bookUrl + ruleBookInfo
        ↓ Book（详情、tocUrl）
tocUrl + ruleToc
        ↓ List<BookChapter>（目录）
chapter.url + ruleContent
        ↓ String（单章正文，保留标准化后的 <img>）
```

每一段都先由 `AnalyzeUrl` 构造 URL/请求并取得响应，再由 `AnalyzeRule` 执行 CSS/Jsoup、XPath、JSONPath、正则或 JavaScript 规则。结果并不存在一个官方的“整本书 JSON”对象：书籍元数据保存在 `Book`，目录保存在 `BookChapter` 列表，正文按章节返回 `String` 并缓存成独立文本文件。

主入口和上述四段调度均在 [`WebBook.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/WebBook.kt)。

## 1. 书源 JSON 的顶层格式

书源的权威数据类是 [`BookSource.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/BookSource.kt)。和“取得一本书”直接相关的结构可概括为：

```jsonc
{
  "bookSourceUrl": "https://example.com",
  "bookSourceName": "示例书源",
  "bookSourceGroup": "分组",
  "bookSourceType": 0,
  "bookUrlPattern": null,
  "enabled": true,
  "enabledExplore": true,
  "header": "{\"User-Agent\":\"...\"}",
  "loginUrl": null,
  "loginUi": null,
  "loginCheckJs": null,
  "coverDecodeJs": null,
  "jsLib": null,
  "concurrentRate": null,

  "searchUrl": "/search?keyword={{key}}&page={{page}}",
  "ruleSearch": { /* 搜索规则 */ },
  "ruleBookInfo": { /* 详情规则 */ },
  "ruleToc": { /* 目录规则 */ },
  "ruleContent": { /* 正文规则 */ }
}
```

`bookSourceType` 的源码注释定义为：`0` 文本、`1` 音频、`2` 图片、`3` 文件。顶层还包含发现页 `exploreUrl/ruleExplore`、排序、注释、自定义变量等字段；它们并非“取指定一本书”链路的必要字段。官方 Web 编辑器对字段名称、类型和提示的集中定义见 [`bookSourceEditConfig.ts`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/modules/web/src/config/bookSourceEditConfig.ts)。

### 1.1 `ruleSearch`

权威模型为 [`SearchRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/SearchRule.kt)：

```jsonc
{
  "checkKeyWord": "校验关键字",
  "bookList": "书籍节点列表规则",
  "name": "书名",
  "author": "作者",
  "intro": "简介",
  "kind": "分类",
  "lastChapter": "最新章节",
  "updateTime": "更新时间",
  "bookUrl": "详情页 URL",
  "coverUrl": "封面 URL",
  "wordCount": "字数"
}
```

注意：`SearchRule` 数据类继承的字段中虽然有 `updateTime`，但该历史版本的 [`BookList.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookList.kt) 实际创建 `SearchBook` 时读取的是 `name/author/kind/wordCount/lastChapter/intro/coverUrl/bookUrl`，未把 `updateTime` 写入结果。

### 1.2 `ruleBookInfo`

权威模型为 [`BookInfoRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/BookInfoRule.kt)：

```jsonc
{
  "init": "可选的详情页预处理/缩小节点规则",
  "name": "书名",
  "author": "作者",
  "intro": "简介",
  "kind": "分类",
  "lastChapter": "最新章节",
  "updateTime": "更新时间",
  "coverUrl": "封面 URL",
  "tocUrl": "目录 URL",
  "wordCount": "字数",
  "canReName": "是否允许详情规则改写书名作者",
  "downloadUrls": "文件类书源的下载 URL（可多条）"
}
```

该版本 [`BookInfo.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookInfo.kt) 实际写入 `name/author/kind/wordCount/latestChapterTitle/intro/coverUrl/tocUrl`；文件类书源改为解析 `downloadUrls`。模型虽声明 `updateTime`，当前实现没有消费它。`tocUrl` 为空时回退到详情页 `baseUrl`；详情与目录同页时复用已下载的 HTML，避免再请求一次。

### 1.3 `ruleToc`

权威模型为 [`TocRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/TocRule.kt)：

```jsonc
{
  "preUpdateJs": "刷新目录前执行的 JS",
  "chapterList": "章节节点列表",
  "chapterName": "章节标题",
  "chapterUrl": "章节 URL",
  "formatJs": "目录去重后逐章格式化标题的 JS",
  "isVolume": "是否卷标题",
  "isVip": "是否 VIP",
  "isPay": "是否已购买",
  "updateTime": "章节附加信息/更新时间",
  "nextTocUrl": "目录下一页 URL（一个或多个）"
}
```

`chapterList` 前缀 `-`/`+`参与顺序控制。目录实现会解析多页、去重、按最终顺序重建 `index`，并用 `formatJs` 二次处理标题，详见 [`BookChapterList.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookChapterList.kt)。

### 1.4 `ruleContent`

权威模型为 [`ContentRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/ContentRule.kt)：

```jsonc
{
  "content": "正文规则",
  "title": "可选；从正文页取得并覆盖章节标题",
  "nextContentUrl": "本章下一分页 URL，不是下一章",
  "webJs": "请求正文时注入网页 JS",
  "sourceRegex": "资源嗅探 URL 特征",
  "replaceRegex": "所有分页合并后的全文净化规则",
  "imageStyle": "图片显示风格，如 FULL",
  "imageDecode": "图片字节二次解密 JS",
  "payAction": "购买操作 JS 或含 {{js}} 的 URL"
}
```

## 2. 规则语言如何执行

核心解释器是 [`AnalyzeRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt)。它的 `Mode` 明确定义五种模式：

| 模式 | 显式/自动识别形式 | 典型用途 |
|---|---|---|
| Default | `@@...` 或默认；`@CSS:` 仍落到 Default | Jsoup/CSS 选择 HTML |
| XPath | `@XPath:`；明显以 `/` 开头时自动识别 | XML/HTML XPath |
| Json | `@Json:`；`$.`、`$[` 或响应为 JSON 时自动识别 | JSONPath |
| Regex | AllInOne 列表规则以 `:` 开头；或规则结构触发正则 | 匹配列表/提取分组 |
| Js | `<js>...</js>`、`@js:` 等 JS 片段 | 任意计算、请求或变换 |

规则可串联执行；`##匹配##替换` 表示正则替换，规则内 `{{...}}` 可执行 JavaScript 或嵌套规则，`@put/@get` 和实体的 `variable` 支持阶段间传值。JS 上下文注入了 `java`、`source`、`book`、`chapter`、`result`、`baseUrl`、`src`、`nextChapterUrl`、cookie/cache 等对象。因此书源并不局限于静态 CSS selector，而是一套可编程抽取 DSL。官方仓库内置规则帮助也列出了默认、XPath、JSON、正则标志及请求/图片参数示例，见 [`ruleHelp.md`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/assets/web/help/md/ruleHelp.md)。

## 3. 四段请求与解析链路

### 3.1 搜索：`searchUrl → SearchBook[]`

[`WebBook.searchBookAwait`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/WebBook.kt#L48) 的步骤是：

1. 用 `searchUrl`、`key`、`page`、书源主页构造 `AnalyzeUrl`。
2. 发起请求；若有 `loginCheckJs`，对响应执行登录检查/重取。
3. 将最终响应 URL 和正文交给 `BookList.analyzeBookList`。
4. `bookList` 先得到候选节点，再在每个节点上执行其余字段规则。
5. `bookUrl/coverUrl` 解析为绝对 URL，书名/作者格式化，简介去 HTML，结果按 `bookUrl` 去重。

特殊情况：如果响应 URL 命中 `bookUrlPattern`，或列表为空，Legado 会把当前响应直接按详情页解析，而不是强制要求搜索列表存在；命中同页时还会暂存 `infoHtml` 供详情阶段复用。

搜索阶段运行时模型 [`SearchBook.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/SearchBook.kt) 的主要字段为：

```jsonc
{
  "bookUrl": "详情页 URL（主键）",
  "origin": "bookSourceUrl",
  "originName": "书源名",
  "type": 0,
  "name": "书名",
  "author": "作者",
  "kind": "分类",
  "coverUrl": "封面 URL",
  "intro": "简介",
  "wordCount": "字数字符串",
  "latestChapterTitle": "最新章节",
  "tocUrl": "目录 URL（搜索后通常尚未补齐）",
  "variable": "规则跨阶段变量 JSON 字符串",
  "time": 0,
  "originOrder": 0,
  "chapterWordCount": -1,
  "respondTime": -1
}
```

### 3.2 详情：`bookUrl → Book`

[`WebBook.getBookInfoAwait`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/WebBook.kt#L152) 优先复用搜索阶段的 `infoHtml`，否则请求 `book.bookUrl`。[`BookInfo.analyzeBookInfo`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookInfo.kt) 先运行可选 `init`，再逐项填充元数据和 `tocUrl`。

持久化模型 [`Book.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/Book.kt) 不仅含网页抽取字段，也混合阅读状态和用户覆盖值：

- 来源/网络：`bookUrl`、`tocUrl`、`origin`、`originName`、`name`、`author`、`kind`、`coverUrl`、`intro`、`type`、`latestChapterTitle`、`wordCount`、`variable`。
- 用户覆盖：`customTag`、`customCoverUrl`、`customIntro`。
- 目录/更新状态：`latestChapterTime`、`lastCheckTime`、`lastCheckCount`、`totalChapterNum`。
- 阅读状态：`durChapterTitle`、`durChapterIndex`、`durChapterPos`、`durChapterTime`、`readConfig`。
- 本地/管理：`charset`、`group`、`canUpdate`、`order`、`originOrder`、`syncTime`。
- 仅运行时：`infoHtml`、`tocHtml`、文件型书源的 `downloadUrls` 等（`@Ignore`，不作为数据库列）。

因此若本项目只想表达“爬到的书籍详情”，不应原样复制整个 `Book`；应只选来源/网络字段，把阅读进度与用户设置放在另一层模型。

### 3.3 目录：`tocUrl → BookChapter[]`

[`WebBook.getChapterListAwait`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/WebBook.kt#L225) 可先运行 `preUpdateJs`，然后复用 `tocHtml` 或请求 `tocUrl`。[`BookChapterList`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookChapterList.kt) 的处理包括：

1. `chapterList` 取节点；逐节点取标题、URL、卷/VIP/购买标识和 `updateTime`。
2. `nextTocUrl` 返回一条时串行追页，返回多条时按线程数并发抓取。
3. 记录已访问 URL 防循环。
4. 合并所有页、去重、处理正反序、重建从 0 开始的 `index`。
5. 可执行 `formatJs` 重写标题，并更新书籍总章节数、最新章节标题和更新时间。

章节持久化模型 [`BookChapter.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/BookChapter.kt)：

```jsonc
{
  "url": "章节地址",
  "title": "章节标题",
  "isVolume": false,
  "baseUrl": "相对 URL 的基准",
  "bookUrl": "所属书籍详情地址",
  "index": 0,
  "isVip": false,
  "isPay": false,
  "resourceUrl": "音频真实地址",
  "tag": "更新时间或其他章节附加信息",
  "wordCount": "本章字数",
  "start": null,
  "end": null,
  "startFragmentId": null,
  "endFragmentId": null,
  "variable": "章节级规则变量 JSON 字符串"
}
```

网络目录通常产生前 11 项及 `variable`；`start/end`、fragment ID 主要服务本地文本/EPUB 场景。

### 3.4 正文：`chapter.url → String`

[`WebBook.getContentAwait`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/WebBook.kt#L299) 的行为：

1. `content` 规则为空时，直接把章节 URL 当内容返回（适配音频/资源型用法）。
2. 卷标题不抓正文，返回其 `tag` 或空串。
3. 详情/目录/章节同页时复用已有 HTML，否则请求章节绝对 URL；请求时把 `webJs` 和 `sourceRegex` 交给 `AnalyzeUrl`，支持动态页面/资源嗅探。
4. [`BookContent.analyzeContent`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookContent.kt) 用 `ruleContent.content` 提取字符串；可用 `title` 覆盖章节标题。
5. 解析 `nextContentUrl`：一条链接时循环串行翻页，多条时并发抓取；当链接等于下一章 URL 时停止，并用 URL 集合防止分页循环。
6. 每页正文经 `HtmlFormatter.formatKeepImg` 标准化，所有页以换行拼接。
7. 最后才执行 `replaceRegex` 全文净化；非卷章节为空则抛 `ContentEmptyException`。
8. `needSave=true` 时按章节写入缓存文本。

正文返回值的数据类型就是 `String`，不是 `{content: ...}` 对象。缓存实现 [`BookHelp.saveContent`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/help/book/BookHelp.kt#L160) 将文本写为按书/章节命名的独立文件；在线文本还可据字符数回写章节 `wordCount`。

## 4. 正文净化、分页和图片的细节

### 4.1 HTML 标准化与净化顺序

[`HtmlFormatter.formatKeepImg`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/utils/HtmlFormatter.kt#L37) 会：

- 把 `div/p/br/hr/h*` 等块标签转换为换行；
- 去注释、其余非图片标签和特殊空白字符；
- 保留 `<img>`，把 `src/data-src/data-*` 中的图片地址转成相对响应 URL 的绝对地址；
- 将图片节点统一成 `<img src="绝对地址[及 URL options]">`；
- 对 HTML entity 再执行 `unescapeHtml4`。

之后多页合并，才运行书源的 `replaceRegex`。另外，Legado 还有用户级 `ReplaceRule`/`ContentProcessor`，属于阅读端个性化净化，不是 `ruleContent` 的书源解析字段，不应和源内 `replaceRegex` 混为一谈。

### 4.2 图片 URL options 与解密

图片不是转成 base64 塞进正文。正文保留 `<img>` 标记，URL 后可携带序列化 options（如单图请求头）；相关官方示例见 [`ruleHelp.md`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/assets/web/help/md/ruleHelp.md)。实际加载图片时，[`ImageUtils.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/utils/ImageUtils.kt) 会选择封面的 `coverDecodeJs` 或正文图片的 `ruleContent.imageDecode`，向 JS 注入图片流/字节和 `src`，要求返回解密后的 `ByteArray`。

`imageStyle` 控制阅读端显示，而不是改变解析后的正文数据；官方注释的默认语义为普通居中，`FULL` 为最大宽度。

## 5. 如果要定义“完整一本书”的对外数据格式

Legado 内部没有这个聚合 DTO。若 `BookSourceFetcher` 需要一次性返回“详情 + 目录 + 正文”，可在不丢 Legado 语义的前提下自定义如下格式：

```jsonc
{
  "book": {
    "bookUrl": "https://example.com/book/1",
    "tocUrl": "https://example.com/book/1/chapters",
    "origin": "https://example.com",
    "originName": "示例书源",
    "type": 0,
    "name": "书名",
    "author": "作者",
    "kind": "分类1,分类2",
    "coverUrl": "https://.../cover.jpg",
    "intro": "简介",
    "wordCount": "100万字",
    "latestChapterTitle": "第100章",
    "variable": null
  },
  "chapters": [
    {
      "index": 0,
      "title": "第一章",
      "url": "https://.../chapter/1",
      "baseUrl": "https://.../book/1/chapters",
      "isVolume": false,
      "isVip": false,
      "isPay": false,
      "tag": "2025-01-01",
      "wordCount": null,
      "variable": null,
      "content": "　　正文第一段\n　　正文第二段\n<img src=\"https://.../1.jpg\">"
    }
  ]
}
```

这是针对当前项目的建议 DTO，**不是 Legado 官方 JSON 返回格式**。实现上也建议保留惰性正文接口：先返回 `book + chapters`，再按章节抓 `content`。原因是 Legado 自身就是按需逐章请求/缓存；全书正文一次性抓取会显著放大网络耗时、内存、并发限制、付费章节和失败恢复问题。

## 6. 对 `BookSourceFetcher` 兼容实现最重要的检查点

1. 不只映射字段名，还要实现规则运行时：CSS/Jsoup、XPath、JSONPath、正则、JS 以及规则串联。
2. 所有 URL 都要按当前请求最终重定向 URL 做绝对化，不能只用书源首页拼接。
3. `book/chapter/source` 级变量和 JS 上下文是许多复杂书源跨阶段传值的基础。
4. 搜索页可能直接就是详情页；详情页和目录页可能同页；目录页和正文页也可能同页，需支持响应复用。
5. 目录和正文分别有独立翻页，且“正文下一页”必须与“下一章”区分。
6. 正文应保留标准化图片标签及 URL options；图片请求头、解密和显示样式是正文完整性的组成部分。
7. `ruleContent.replaceRegex` 是多页合并后的源级净化；不要提前对单页执行导致跨页规则失效。
8. 模型声明字段不等于当前实现一定消费。该历史版本中 `ruleSearch.updateTime` 和 `ruleBookInfo.updateTime` 即是典型例子。

## 7. 一手资料索引

- 官方历史提交：[`ef9b4c28`](https://github.com/gedoor/legado/commit/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad)
- 书源模型：[`BookSource.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/BookSource.kt)
- 四类规则模型：[`SearchRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/SearchRule.kt)、[`BookInfoRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/BookInfoRule.kt)、[`TocRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/TocRule.kt)、[`ContentRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/rule/ContentRule.kt)
- 请求与总调度：[`WebBook.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/WebBook.kt)
- 四段解析：[`BookList.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookList.kt)、[`BookInfo.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookInfo.kt)、[`BookChapterList.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookChapterList.kt)、[`BookContent.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/webBook/BookContent.kt)
- 运行时实体：[`SearchBook.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/SearchBook.kt)、[`Book.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/Book.kt)、[`BookChapter.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/data/entities/BookChapter.kt)
- 规则解释器：[`AnalyzeRule.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeRule.kt)
- HTML/图片/缓存：[`HtmlFormatter.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/utils/HtmlFormatter.kt)、[`ImageUtils.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/utils/ImageUtils.kt)、[`BookHelp.kt`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/java/io/legado/app/help/book/BookHelp.kt)
- 官方仓库内置编辑器/帮助：[`bookSourceEditConfig.ts`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/modules/web/src/config/bookSourceEditConfig.ts)、[`ruleHelp.md`](https://github.com/gedoor/legado/blob/ef9b4c28ed9bb52c7a2e170926e0ce9b21b346ad/app/src/main/assets/web/help/md/ruleHelp.md)
