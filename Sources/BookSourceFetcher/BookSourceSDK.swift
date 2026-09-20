import Foundation

/// BookSourceFetcher SDK 的稳定入口配置。
public struct BookSourceSDKConfiguration: Sendable, Equatable {
    /// 同时执行搜索的最大书源数。
    public let maxConcurrentSources: Int
    /// 单个书源的请求超时，单位为秒。
    public let sourceTimeout: TimeInterval
    /// 每个书源保留的最大搜索结果数。
    public let maxResultsPerSource: Int
    /// 实际参与搜索的最大书源数；`nil` 表示不限制。
    public let maxSources: Int?

    public init(
        maxConcurrentSources: Int = 16,
        sourceTimeout: TimeInterval = 10,
        maxResultsPerSource: Int = 30,
        maxSources: Int? = nil
    ) {
        self.maxConcurrentSources = max(1, maxConcurrentSources)
        self.sourceTimeout = max(0.1, sourceTimeout)
        self.maxResultsPerSource = max(0, maxResultsPerSource)
        if let maxSources, maxSources > 0 {
            self.maxSources = maxSources
        } else {
            self.maxSources = nil
        }
    }

    public static let `default` = BookSourceSDKConfiguration()
}

/// BookSourceFetcher SDK 的高层门面。
///
/// 该 actor 统一管理请求会话、书源、Cookie 和熔断状态，可在 SwiftUI、UIKit
/// 以及 AppKit 工程中作为长生命周期实例复用。
public actor BookSourceSDK {
    /// 当前 SDK API 版本。发布新产物时由打包脚本校验并写入产物名。
    public static let version = "1.0.0"

    private let fetcher: PaquBookSourceFetcher

    /// 使用已解码的 Legado 书源创建 SDK。
    public init(
        sources: [PaquBookSource],
        configuration: BookSourceSDKConfiguration = .default,
        session: URLSession? = nil,
        cookieStore: CookieStore? = nil
    ) {
        fetcher = PaquBookSourceFetcher(
            sources: sources,
            session: session,
            cookieStore: cookieStore,
            maxConcurrentSources: configuration.maxConcurrentSources,
            sourceTimeout: configuration.sourceTimeout,
            maxResultsPerSource: configuration.maxResultsPerSource,
            maxSources: configuration.maxSources
        )
    }

    /// 使用 SDK 内置的精选书源创建实例，无需联网加载书源配置。
    public static func bundled(
        configuration: BookSourceSDKConfiguration = .default,
        session: URLSession? = nil,
        cookieStore: CookieStore? = nil
    ) throws -> BookSourceSDK {
        let sources = try PaquBookSourceLoader.loadBundled()
        return BookSourceSDK(
            sources: sources,
            configuration: configuration,
            session: session,
            cookieStore: cookieStore
        )
    }

    /// 从本地 Legado JSON 文件创建实例。
    public static func local(
        fileURL: URL,
        configuration: BookSourceSDKConfiguration = .default,
        session: URLSession? = nil,
        cookieStore: CookieStore? = nil
    ) throws -> BookSourceSDK {
        let sources = try PaquBookSourceLoader.load(localFile: fileURL.path)
        return BookSourceSDK(
            sources: sources,
            configuration: configuration,
            session: session,
            cookieStore: cookieStore
        )
    }

    /// 从远程 Legado JSON 地址下载书源并创建实例。
    public static func remote(
        sourceURL: URL,
        configuration: BookSourceSDKConfiguration = .default,
        session: URLSession = .shared,
        cookieStore: CookieStore? = nil
    ) async throws -> BookSourceSDK {
        let sources = try await PaquBookSourceLoader.load(from: sourceURL, session: session)
        return BookSourceSDK(
            sources: sources,
            configuration: configuration,
            session: session,
            cookieStore: cookieStore
        )
    }

    /// 搜索并合并多个书源的结果；达到整体时间预算后返回已完成的部分结果。
    public func search(
        _ bookName: String,
        timeout: TimeInterval? = nil
    ) async -> BookSourceSearchResponse {
        await fetcher.fetch(bookName: bookName, overallTimeout: timeout)
    }

    /// 流式返回各书源的搜索批次。批次间未去重，适合调用方渐进渲染。
    public func searchStream(
        _ bookName: String,
        timeout: TimeInterval? = nil
    ) -> AsyncStream<[BookSourceSearchItem]> {
        fetcher.fetchStream(bookName: bookName, overallTimeout: timeout)
    }

    /// 执行搜索、详情和目录解析完整链路。
    public func resolve(_ bookName: String, maxResults: Int = 10) async -> [ResolvedBook] {
        await fetcher.resolve(bookName: bookName, maxResults: maxResults)
    }

    /// 获取指定书源的书籍详情。
    public func bookInfo(bookURL: String, sourceName: String) async -> BookInfo? {
        await fetcher.fetchBookInfo(bookURL: bookURL, sourceName: sourceName)
    }

    /// 获取指定书源的目录。
    public func chapters(tocURL: String, sourceName: String) async -> [Chapter] {
        await fetcher.fetchToc(tocURL: tocURL, sourceName: sourceName)
    }

    /// 为域名注入登录 Cookie，例如 `session=xxx; uid=123`。
    public func setCookie(_ cookie: String, forHost host: String) {
        fetcher.injectCookie(cookie, forHost: host)
    }

    /// 为匹配到的书源注入登录 Cookie。
    public func setCookie(_ cookie: String, forSourceNamed sourceName: String) {
        fetcher.injectCookie(cookie, forSourceNamed: sourceName)
    }

    /// 清除 SDK 实例持有的全部 Cookie。
    public func clearCookies() {
        fetcher.cookieStore.clear()
    }
}

/// SDK 友好命名；底层类型名继续保留以兼容已有调用方。
public typealias BookSourceSearchResponse = BookFetchResponse
public typealias BookSourceSearchItem = BookFetchItem
