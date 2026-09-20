# BookSourceFetcher

基于 Legado（阅读 App）书源格式的原生 Swift 解析库，可直接作为 iOS/macOS Swift Package 使用。

推荐通过线程安全的 `BookSourceSDK` 门面接入。完整的安装、初始化、流式搜索、Cookie、工程配置和发版说明见 [SDK_INTEGRATION.md](SDK_INTEGRATION.md)。生成可分发 SDK ZIP：

```bash
./Scripts/build-sdk.sh
```

本项目支持搜索书名、读取详情、分页目录和章节正文，以及解析/解密封面 URL。它不是 Android Legado 的桥接服务，也不依赖 Android 运行时；书源 JSON 在 App 内解码，页面请求和规则执行都在本机完成。规则兼容范围和完整阅读接口见下文，不保证所有 Legado 书源可用。

## 获取可阅读的书

```swift
let sdk = try BookSourceSDK.bundled()
let result = try await sdk.read("三国演义", author: "罗贯中", chapterLimit: 3)
if result.complete, let book = result.book {
    print(book.name, book.chapters.count)
    for chapter in result.contents { print(chapter.chapter.title, chapter.content) }
}
```

`read` 会尝试同名候选书源，详情或正文失败时换源，不跨源拼接章节。默认验证首章；`success` 表示至少取得一章正文，`complete` 表示本次选定章节全部取得，并非整本下载完成。完整字段、按需加载与限制见 [SDK 接入文档](SDK_INTEGRATION.md#完整阅读接口)。

```bash
swift run fetcher-cli --read "三国演义" --chapters 3
# 已知详情地址时：
swift run fetcher-cli --read-url "详情页URL" "书源bookSourceUrl" "书源JSON路径" --chapters 3
```

## 功能

从书源 JSON 配置出发，按书籍名称并发搜索多个书源，解析 HTML / JSON 响应，合并去重，返回统一格式结果。

## 使用方法

```swift
import BookSourceFetcher

// 使用随 SDK 打包的精选书源
let sdk = try BookSourceSDK.bundled()
let response = await sdk.search("斗破苍穹", timeout: 15)

// response.success: Bool
// response.data.results: [BookSourceSearchItem]
// 每条：title / author / isbn / publisher / cover_url / provider
let item = response.data.results.first
item?.title      // 书名
item?.author     // 作者（可为空）
item?.isbn       // 始终为 nil（网络小说源无 ISBN）
item?.publisher  // 始终为 nil
item?.coverUrl   // 封面 URL（可为空）
item?.provider   // 书源名，如 "⭐ 猫眼看书"

// 需要简介、封面和目录时，执行完整链路：搜索 -> 详情 -> 目录
let books = await sdk.resolve("斗破苍穹", maxResults: 10)
for book in books {
    print(book.title, book.intro ?? "", book.coverUrl ?? "")
    for chapter in book.chapters {
        print(chapter.name, chapter.url)
    }
}
```

## 集成到 iOS

在 Xcode 中将 `Tools/BookSourceFetcher` 作为本地 Swift Package 添加，或把该目录提交到自己的 Git 仓库后通过 **Package Dependencies** 引入。最低平台为 iOS 16。App 启动后加载书源并调用 `resolve`：

```swift
let sourceURL = URL(string: "https://cdn.mgz.la/shuyuan/250701%E6%9C%80%E5%90%8E%E4%B8%80%E7%89%88%E4%B8%80%E7%A8%8B.json")!
let sources = try await PaquBookSourceLoader.load(from: sourceURL)
let fetcher = PaquBookSourceFetcher(sources: sources)
let books = await fetcher.resolve(bookName: "斗破苍穹")
```

`ResolvedBook` 的字段为 `title`、`author`、`intro`、`coverUrl`、`provider`、`bookUrl`、`chapters`。`coverUrl` 已应用书源的 `coverDecodeJs`（脚本返回 URL 的场景）；如果某个源要求对图片字节做解密，应在 App 下载图片后按该源脚本提供的算法处理，解析库会保留原始 URL 作为降级结果。

## 合规元数据搜索：OpenLibrary（用于正式上架）

对 OpenLibrary（Internet Archive 开放图书元数据，免费、无版权问题）做搜索，输出结构化 JSON：

```swift
import BookSourceFetcher

let response = await OpenLibraryFetcher.search(query: "武极天下")
// response.results: [OpenLibraryBook] —— title/author/cover_url/book_url/language/year
// file_format / file_size / rating：OpenLibrary 搜索接口不提供，恒为 nil
```

命令行：

```bash
./.build/debug/fetcher-cli --openlib "武极天下"
```

> 封面来自 `https://covers.openlibrary.org/b/id/{cover_i}-L.jpg`，属 OpenLibrary 公开可用的封面服务；元数据（书名/作者/年份/语言）均为事实信息，可安全用于 App Store 上架。
>
> 注意：OpenLibrary 要求查询词至少 3 个字符（`三体` 这类 2 字书名会返回 422），且只收录正式出版物（有 ISBN 的书），不收录网文连载。

## 命令行验证

```bash
swift build
./.build/debug/fetcher-cli "斗破苍穹" [书源JSON路径或URL]
```

## 架构

源码按职责分目录，仍属于同一个 Swift Package 模块，公开 API 和 import 方式不变：

```text
Sources/BookSourceFetcher/
├── SDK/           # 对外 SDK 门面与配置
├── Models/        # 书源、搜索结果、书籍及章节数据模型
├── Sources/       # 书源配置加载
├── Fetching/      # 多源协调、搜索、详情、目录与正文抓取
├── RuleEngine/    # 规则 DSL、JavaScript、JSONPath、XPath
├── Networking/    # 请求构建、Cookie、登录态与 WebView
├── Concurrency/   # 并发控制、限流与熔断
├── Providers/     # OpenLibrary 等独立数据提供方
├── Utilities/     # 书名归一化与封面解码
└── Resources/     # 内置书源 JSON
```

命令行入口保留在 `Sources/fetcher-cli/`，测试保留在 `Tests/BookSourceFetcherTests/`。SwiftPM 自动递归发现源码，无需逐文件配置路径。

- `PaquBookSource` / `SearchRule` ... — 书源模型（Legado 格式 Codable，含 loginUrl/loginUi/loginCheckJs/coverDecodeJs/jsLib 字段）
- `PaquBookSourceLoader` — 下载/解析书源 JSON
- `SearchRequestBuilder` — 根据 searchUrl + {{key}}/{{page}} 构建 GET/POST 请求
  - 支持 `@js:` / `<js>` 动态 URL（执行 JS 后取结果作为 URL）
  - 支持单引号 JS 配置对象解析（`parseObject`）
  - 支持从 `java.put("headers", ...)` 存储读取请求头（`applyStoredHeaders`）
  - 自动清理 `@js` 尾部逗号残留（`stripTrailingComma`）
  - CookieJar：请求前回传该域名 Cookie（对应 Legado enabledCookieJar）
- `JSRuntime` — JavaScriptCore 桥接层，为 Legado 规则里的 `java.*` 提供等价实现：
  - `java.md5Encode(str)` — CryptoKit `Insecure.MD5` 实现
  - `java.base64Encode(str)` — Base64 编码
  - `java.put(key, value)` / `java.get(key)` — 跨步骤存储（如保存签名 headers）
  - `java.getCookie([host])` / `java.putCookie(k,v)` / `java.removeCookie(k)` — Cookie 桥接
  - `parseObject` — 把 `{a:'b'}` 单引号 JS 对象字面量转成 JSON
- `CookieStore` — 线程安全的按域名 Cookie 容器（保存 Set-Cookie / 回传 / 外部注入，父域回退）
- `LoginGate` — 登录态判断（loginUrl 非空时执行 loginCheckJs，false 则跳过该源）
- `WebViewRenderer` — Layer 4 真实浏览器：WKWebView 加载 + 等待 JS 渲染 + 执行 webJs / 取渲染后 HTML
- `BookSourceSearcher` — 发起 HTTP 请求、用 SwiftSoup 解析 HTML 或 JSON
- `RuleEngine` — 解析 Legado 规则 DSL：
  - CSS 选择器（`a.1@text`、`img@src`、`.class@text`）
  - JSONPath（`$.data[*]`、`$.result.books`、`$..name`）与裸字段路径（`data.books`、`original_title`）
  - 正则替换（`##pattern##replacement`）
  - 组合规则（`&&` 拼接、`||` 或）
  - 模板变量（`{{key}}`、`{{page}}`、`{{$.id}}`）
  - JS 规则（`@js:...`、`<js>...</js>`，用 JavaScriptCore 执行）
- `PaquBookSourceFetcher` — 多源并发（TaskGroup）、按书名归一化合并去重、返回 `BookFetchResponse`

## 反爬处理（对照 Legado 的四层模型）

| 层 | 机制 | 实现状态 |
| --- | --- | --- |
| 1. 请求伪装 | UA / Referer / Cookie 头伪装 | ✅ 已实现 |
| 2. 动态签名 | `@js` / `java.md5Encode` 等签名参数 | ✅ 已实现（救回七猫） |
| 3. 登录态 | loginUrl + loginCheckJs + CookieJar | ✅ 已实现（CookieStore + LoginGate + cookie 注入） |
| 4. 真实浏览器 | webView + webJs | ✅ 已实现（WebViewRenderer / WKWebView） |

## 登录态使用（Layer 3）

```swift
// SDK 不接管登录 UI；业务登录完成后注入 Cookie
await sdk.setCookie("token=xxx; uid=123", forHost: "api-bc.wtzw.com")
// 或按书源名注入（自动定位域名）
await sdk.setCookie("token=xxx; uid=123", forSourceNamed: "七猫小说")

let response = await sdk.search("斗破苍穹", timeout: 15)
```

CLI 注入 Cookie：

```bash
./.build/debug/fetcher-cli --cookie "api-bc.wtzw.com=token=xxx;uid=123" "斗破苍穹" shuyuan_filtered.json
```

## 真实浏览器使用（Layer 4）

```swift
#if canImport(WebKit)
let renderer = await MainActor.run { WebViewRenderer() }
let html = await renderer.loadHTML(url: "https://example.com")      // 渲染后 HTML
let content = await renderer.runWebJs(url: "https://...", js: "...") // 执行 webJs 取结果
#endif
```

CLI 测试 WebView 渲染：

```bash
./.build/debug/fetcher-cli --webview "https://example.com"
```

> WKWebView 依赖主线程 RunLoop（macOS 需 NSApplication、iOS 需 UIApplication）。App 环境直接可用；CLI 下 fetcher-cli 已用 `RunLoop.main.run()` 驱动，实测可渲染并执行页面 JS。

## 注意

- 这些书源是网络小说源，无 ISBN / 出版社字段。示例中 isbn 字段为空。
- 部分书源可能有反爬（JS 跳转/验证码）；请求失败书源自动降级跳过，不影响其他源。
- 请在合法合规的前提下使用。
