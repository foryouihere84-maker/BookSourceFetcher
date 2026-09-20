# BookSourceFetcher SDK 接入文档

BookSourceFetcher 是原生 Swift SDK，用于加载 Legado 书源并完成书名搜索、详情解析、目录解析和 Cookie 管理。SDK 支持 iOS 16+、macOS 13+，公开模块名为 `BookSourceFetcher`。

## 1. 获取 SDK

### 方式一：接入仓库内的本地 Package

在 Xcode 中选择 **File > Add Package Dependencies > Add Local**，选择：

```text
Tools/BookSourceFetcher
```

将 `BookSourceFetcher` product 添加到 App target。在当前仓库中，Rivulet 已通过 `../../Tools/BookSourceFetcher` 使用这种方式接入。

也可以在另一个 Swift Package 中声明本地依赖：

```swift
dependencies: [
    .package(path: "../BookSourceFetcher")
],
targets: [
    .target(
        name: "YourAppCore",
        dependencies: ["BookSourceFetcher"]
    )
]
```

### 方式二：使用分发包

在 SDK 目录执行：

```bash
./Scripts/build-sdk.sh
```

脚本会先执行测试，再生成：

```text
dist/BookSourceFetcherSDK-1.0.0.zip
dist/BookSourceFetcherSDK-1.0.0.zip.sha256
```

解压 ZIP 后，将其中的 `BookSourceFetcherSDK` 目录按本地 Package 添加到 Xcode。自动化环境已单独执行测试时，可用 `SKIP_TESTS=1 ./Scripts/build-sdk.sh` 跳过重复测试。也可传入版本号覆盖产物名，例如 `./Scripts/build-sdk.sh 1.0.1-beta.1`；正式发布时应同时更新 `BookSourceSDK.version` 并创建对应 Git tag。

### 方式三：Git URL

将 `Tools/BookSourceFetcher` 拆分或发布为独立 Git 仓库并创建语义化版本 tag 后，可在 Xcode 中通过仓库 URL 接入。Swift Package 声明示例：

```swift
.package(url: "https://your-host/BookSourceFetcher.git", from: "1.0.0")
```

## 2. 最小接入

内置精选书源随 SDK resource bundle 打包，无需单独复制 JSON：

```swift
import BookSourceFetcher

let sdk = try BookSourceSDK.bundled()
let response = await sdk.search("斗破苍穹", timeout: 15)

guard response.success, let book = response.data.results.first else {
    return
}

print(book.title)
print(book.author ?? "未知作者")
print(book.coverUrl ?? "无封面")
print(book.provider ?? "未知书源")
```

`search` 对书名做归一化后精确匹配。超时表示整次多源搜索的时间预算；到期时返回已经完成的部分结果，不会因为仍有慢源而丢弃已有结果。

建议为一个业务域长期持有一个 `BookSourceSDK` 实例，以复用 Cookie、限速和熔断状态。`BookSourceSDK` 是 actor，可安全地从多个并发任务调用。

## 3. 初始化方式

### 内置书源

```swift
let configuration = BookSourceSDKConfiguration(
    maxConcurrentSources: 8,
    sourceTimeout: 6,
    maxResultsPerSource: 5,
    maxSources: 20
)
let sdk = try BookSourceSDK.bundled(configuration: configuration)
```

### 远程书源

```swift
let sourceURL = URL(string: "https://example.com/sources.json")!
let sdk = try await BookSourceSDK.remote(
    sourceURL: sourceURL,
    configuration: .init(maxConcurrentSources: 8, sourceTimeout: 8)
)
```

远程地址必须返回 Legado 书源 JSON 数组。下载失败或 JSON 不合法时，该方法会抛出错误，调用方应展示自己的降级状态或回退到 `bundled()`。

### 本地 JSON

```swift
let fileURL = Bundle.main.url(forResource: "my_sources", withExtension: "json")!
let sdk = try BookSourceSDK.local(fileURL: fileURL)
```

需要自行组合或筛选书源时，可以先调用 `PaquBookSourceLoader.decode(_:)`，再使用 `BookSourceSDK(sources:)`。

## 4. 搜索与完整解析

普通搜索只请求搜索页，响应更快：

```swift
let response: BookSourceSearchResponse = await sdk.search("万古江河", timeout: 15)
let items: [BookSourceSearchItem] = response.data.results
```

完整解析会继续请求详情和目录，网络成本更高：

```swift
let books = await sdk.resolve("斗破苍穹", maxResults: 3)
for book in books {
    print(book.title, book.intro ?? "")
    for chapter in book.chapters {
        print(chapter.name, chapter.url)
    }
}
```

已经持有 URL 和书源名称时，可分别调用：

```swift
let info = await sdk.bookInfo(bookURL: bookURL, sourceName: provider)
let chapters = await sdk.chapters(tocURL: tocURL, sourceName: provider)
```

## 5. 流式搜索

流式接口在单个书源完成后立即产生一个批次，适合渐进更新 UI：

```swift
for await batch in await sdk.searchStream("斗破苍穹", timeout: 15) {
    // batch 内已经过滤无效条目，但不同批次之间尚未去重。
    resultPool.append(contentsOf: batch)
}
```

取消消费流的父 `Task`，或结束迭代，会取消仍在执行的书源任务。调用方需要按归一化书名和业务字段完成跨批次去重。

## 6. 登录 Cookie

部分书源要求登录态。SDK 不收集账号密码，业务侧完成登录后注入 Cookie：

```swift
await sdk.setCookie("token=xxx; uid=123", forHost: "api.example.com")

// 或按书源名称模糊匹配其域名
await sdk.setCookie("token=xxx; uid=123", forSourceNamed: "示例书源")

// 退出登录
await sdk.clearCookies()
```

不要将 Cookie 写入日志或分析事件。需要跨启动保留登录态时，应由 App 使用 Keychain 保存，并在创建 SDK 后重新注入。

## 7. App 工程配置

- SDK 最低支持 iOS 16 和 macOS 13，需要 Swift 5.9 或更高版本的 Package 工具链。
- 网络请求使用 `URLSession`。生产书源应使用 HTTPS；若必须访问 HTTP，需要由宿主 App 自行配置 ATS 例外并承担安全风险。
- 带 `webView: true` 或 `webJs` 的规则会使用 WebKit。相关调用需要 App 主线程 RunLoop，UIKit/SwiftUI App 环境无需额外启动 RunLoop。
- 内置 `usable_sources.json` 由 Swift Package resource bundle 管理。不要依赖宿主 App 的 `Bundle.main` 查找它。
- SDK 内含第三方依赖 SwiftSoup，Swift Package Manager 会自动解析。宿主工程无需再次手工链接。

## 8. API 与兼容性

推荐新接入只使用 `BookSourceSDK`、`BookSourceSDKConfiguration`、`BookSourceSearchResponse` 和 `BookSourceSearchItem`。已有项目仍可继续使用 `PaquBookSourceFetcher`、`PaquBookSourceLoader` 等底层公开 API。

版本策略遵循语义化版本：

- patch：缺陷修复，不改变公开调用方式；
- minor：向后兼容地增加能力；
- major：存在公开 API 或行为不兼容变更。

书源由第三方站点规则驱动，站点变更、反爬、登录限制或网络故障都可能导致单源无结果。业务 UI 应区分“搜索无匹配”和网络降级，但不要把单个书源失败视为整个 SDK 请求失败。接入方还需自行确认书源、内容及封面的使用授权和当地合规要求。
