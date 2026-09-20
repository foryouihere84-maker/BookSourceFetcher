//
//  PaquBookSourceFetcher.swift
//  BookSourceFetcher
//
//  书源爬取接口主入口。
//  用法：
//    let fetcher = PaquBookSourceFetcher()
//    let response = try await fetcher.fetch(bookName: "有理想就有疼痛")
//  返回 { success, data: { results: [...] } } 格式。
//

import Foundation

/// 书源爬取接口。
public struct PaquBookSourceFetcher {

    private let session: URLSession
    private let sources: [PaquBookSource]
    /// 共享 Cookie 存储（登录态 + CookieJar）。
    public let cookieStore: CookieStore
    /// 请求限速器（根据各书源 concurrentRate 字段）。
    private let rateLimiter: RateLimiter
    /// 源级熔断器（连续失败跳过 + 冷却期）。
    private let breaker: CircuitBreaker
    /// 并发搜索的书源数量上限（信号量许可数，非线程数）。
    public var maxConcurrentSources: Int
    /// 单个书源超时（秒）。
    public var sourceTimeout: TimeInterval
    /// 每个源搜索的最大结果数。
    public var maxResultsPerSource: Int
    /// 搜索时最多使用的源数（按 tier 降序取前 N 个）。0 或 nil 表示不限。
    /// 80 源中大部分质量差（tier=1 仅搜索），取前 20 即可覆盖全通+搜索+简介源。
    /// 不影响 `audit()` 全量审计。
    public var maxSources: Int?

    public init(
        sources: [PaquBookSource],
        session: URLSession? = nil,
        cookieStore: CookieStore? = nil,
        breaker: CircuitBreaker? = nil,
        maxConcurrentSources: Int = 16,
        sourceTimeout: TimeInterval = 10,
        maxResultsPerSource: Int = 30,
        maxSources: Int? = nil
    ) {
        let ordered = Self.orderByTier(PaquBookSourceLoader.enabledSources(sources))
        if let maxSources, maxSources > 0, maxSources < ordered.count {
            self.sources = Array(ordered.prefix(maxSources))
        } else {
            self.sources = ordered
        }
        self.cookieStore = cookieStore ?? CookieStore()
        self.rateLimiter = RateLimiter(sources: self.sources)
        self.breaker = breaker ?? CircuitBreaker()
        self.maxConcurrentSources = max(1, maxConcurrentSources)
        self.sourceTimeout = sourceTimeout
        self.maxResultsPerSource = max(0, maxResultsPerSource)

        if let session {
            self.session = session
        } else {
            // ephemeral：不落盘、不用共享 URLCache，避免 _CFCachedURLResponse/CFURLCacheNode 随搜索累积（内存驻留）。
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = sourceTimeout
            config.timeoutIntervalForResource = sourceTimeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    /// 按审计 tier 降序排序：全通源(tier4)优先、逐层递减、仅搜索(tier1)最后，让快源先发出。
    /// 无审计元数据（如测试 mock 源）视为 tier 0，排在最后。
    private static func orderByTier(_ sources: [PaquBookSource]) -> [PaquBookSource] {
        sources.sorted { lhs, rhs in
            let lt = lhs.audit?.tierValue ?? 0
            let rt = rhs.audit?.tierValue ?? 0
            if lt != rt { return lt > rt }
            let lc = lhs.audit?.searchCountValue ?? 0
            let rc = rhs.audit?.searchCountValue ?? 0
            return lc > rc
        }
    }

    /// 便捷初始化：从书源 URL 加载。
    public static func load(sourceURL: URL) async throws -> PaquBookSourceFetcher {
        let sources = try await PaquBookSourceLoader.load(from: sourceURL)
        return PaquBookSourceFetcher(sources: sources)
    }

    /// 便捷初始化：从内置 bundle 加载打包进库的精选可用源（无需联网）。
    public static func loadBundled() throws -> PaquBookSourceFetcher {
        let sources = try PaquBookSourceLoader.loadBundled()
        return PaquBookSourceFetcher(sources: sources)
    }

    /// 发起搜索。返回与用户要求一致的结构。
    /// - Parameter overallTimeout: 整次搜索的时间预算（秒）。到点后取消未完成的源，
    ///   返回**已收集到的部分结果**（而非空数组）。nil 表示不设整体超时，等全部源返回。
    public func fetch(bookName: String, overallTimeout: TimeInterval? = nil) async -> BookFetchResponse {
        let key = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return BookFetchResponse(success: false, results: [])
        }

        let allItems = await searchAllSources(key: key, overallTimeout: overallTimeout)
        let merged = mergeAndDedupe(allItems, key: key)

        return BookFetchResponse(success: !merged.isEmpty, results: merged)
    }

    /// 流式搜索：每完成一个源就 yield 该源映射后的结果批次（**未跨源去重**）。
    /// 与 `fetch` 的区别：不必等全部源完成，调用方（App 层结果池）可渐进渲染，
    /// 跨源去重/过滤/排序由调用方统一负责，避免「先到先得」造成重复条目。
    /// - Parameter overallTimeout: 整次搜索的时间预算（秒）。到点取消未完成源，
    ///   已完成的批次仍会 yield（部分结果语义）。
    public func fetchStream(bookName: String, overallTimeout: TimeInterval? = nil) -> AsyncStream<[BookFetchItem]> {
        let key = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AsyncStream { continuation in
            guard !key.isEmpty else {
                continuation.finish()
                return
            }

            let task = Task {
                for await items in self.searchAllSourcesStream(key: key, overallTimeout: overallTimeout) {
                    let mapped = items.compactMap(Self.mapToFetchItem)
                    if !mapped.isEmpty {
                        continuation.yield(mapped)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 把单条解析结果映射为对外结果项；空书名（解析失败脏数据）返回 nil 剔除。
    private static func mapToFetchItem(_ item: ParsedBookItem) -> BookFetchItem? {
        guard item.isValid else { return nil }
        let author = (item.author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var result = BookFetchItem(
            title: item.title ?? "",
            author: author.isEmpty ? nil : author,
            intro: item.intro,
            isbn: nil,
            publisher: nil,
            coverUrl: item.coverUrl,
            provider: item.provider
        )
        result.bookUrl = item.bookUrl
        result.sourceUrl = item.sourceUrl
        result.kind = item.kind
        result.wordCount = item.wordCount
        result.latestChapterTitle = item.latestChapterTitle
        result.variables = item.variables
        return result
    }

    /// 搜索后继续执行 ruleBookInfo 和 ruleToc，供 iOS 直接取得简介、封面和目录。
    /// 搜索结果没有详情 URL 的书源仍会返回搜索页已有字段，chapters 为空。
    public func resolve(bookName: String, maxResults: Int = 10) async -> [ResolvedBook] {
        let key = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, maxResults > 0 else { return [] }

        let items = await searchAllSources(key: key)
        var resolved: [ResolvedBook] = []
        var seen = Set<String>()

        for item in items {
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            let identity = "\(BookTitleNormalizer.normalize(title))|\(item.author ?? "")|\(item.provider)"
            guard seen.insert(identity).inserted else { continue }
            guard let source = sources.first(where: { $0.bookSourceName == item.provider }) else { continue }

            var intro = item.intro
            var author = item.author
            var cover = item.coverUrl
            var chapters: [Chapter] = []

            if let bookURL = item.bookUrl, !bookURL.isEmpty,
               let info = await BookInfoFetcher.fetchInfo(
                   bookURL: bookURL,
                   source: source,
                   session: session,
                   cookieStore: cookieStore
               ) {
                intro = info.intro ?? intro
                author = info.author ?? author
                cover = info.coverUrl ?? cover
                let tocURL = (info.tocUrl?.isEmpty == false) ? info.tocUrl! : bookURL
                chapters = await TocFetcher.fetchToc(
                    tocURL: tocURL,
                    source: source,
                    session: session,
                    cookieStore: cookieStore
                )
            }

            resolved.append(ResolvedBook(
                title: title,
                author: author,
                intro: intro,
                coverUrl: cover,
                provider: item.provider,
                bookUrl: item.bookUrl,
                chapters: chapters
            ))
            if resolved.count >= maxResults { break }
        }
        return resolved
    }

    /// 注入登录 Cookie（爬虫无 UI，替代 Legado 的 webView 登录）。
    /// - Parameters:
    ///   - cookieString: 形如 "token=xxx; uid=123" 的 Cookie 字符串。
    ///   - host: 目标书源域名（如 "api-bc.wtzw.com"）。
    public func injectCookie(_ cookieString: String, forHost host: String) {
        cookieStore.inject(cookieString: cookieString, forHost: host)
    }

    /// 按书源名注入登录 Cookie（自动定位域名）。
    public func injectCookie(_ cookieString: String, forSourceNamed name: String) {
        guard let source = sources.first(where: { $0.bookSourceName.contains(name) || name.contains($0.bookSourceName) }),
              let host = source.host else { return }
        cookieStore.inject(cookieString: cookieString, forHost: host)
    }

    // MARK: - 书籍详情页获取

    /// Resolve a selected search candidate without losing its source identity or rule variables.
    public func openBook(_ candidate: BookFetchItem) async throws -> ReadableBook {
        guard let url = candidate.bookUrl else { throw BookReadingError.empty("书籍详情地址") }
        let source = try readingSource(url: candidate.sourceUrl, name: candidate.provider)
        let book = ReadableBook(bookUrl: url, sourceUrl: source.bookSourceUrl ?? "", sourceName: source.bookSourceName,
            name: candidate.title, author: candidate.author, intro: candidate.intro, coverUrl: candidate.coverUrl,
            kind: candidate.kind, wordCount: candidate.wordCount, latestChapterTitle: candidate.latestChapterTitle,
            variables: candidate.variables ?? [:])
        return try await readingPipeline(source, variables: book.variables).resolve(book)
    }

    /// Open a known detail URL, retaining the full metadata and chapter model.
    public func openBook(bookURL: String, sourceURL: String) async throws -> ReadableBook {
        let source = try readingSource(url: sourceURL, name: nil)
        return try await readingPipeline(source, variables: [:]).resolve(
            ReadableBook(bookUrl: bookURL, sourceUrl: sourceURL, sourceName: source.bookSourceName))
    }

    public func fetchContent(book: ReadableBook, chapter: ReadableChapter, maxPages: Int = 100) async throws -> ChapterContent {
        let source = try readingSource(url: book.sourceUrl, name: nil)
        return try await readingPipeline(source, variables: book.variables, maxPages: maxPages).content(book: book, chapter: chapter)
    }

    /// Try exact-title candidates in source priority order. Success requires actual chapter text.
    /// Chapter content is never combined across editions/sources. A partial result stays with its book.
    public func readBook(bookName: String, author: String? = nil, chapterLimit: Int = 1,
                         searchTimeout: TimeInterval? = 20, minimumContentLength: Int = 80) async throws -> BookReadResponse {
        guard !bookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, chapterLimit > 0 else {
            throw BookReadingError.empty("书名或请求章节数量")
        }
        let items = await searchAllSources(key: bookName, overallTimeout: searchTimeout)
        try Task.checkCancellation()
        let normalized = BookTitleNormalizer.normalize(bookName)
        let candidates = items.filter {
            BookTitleNormalizer.normalize($0.title ?? "") == normalized &&
            (author == nil || $0.author?.trimmingCharacters(in: .whitespacesAndNewlines) == author?.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted { lhs, rhs in
            let left = sources.firstIndex { $0.bookSourceUrl == lhs.sourceUrl && $0.bookSourceName == lhs.provider } ?? Int.max
            let right = sources.firstIndex { $0.bookSourceUrl == rhs.sourceUrl && $0.bookSourceName == rhs.provider } ?? Int.max
            return left == right ? (lhs.bookUrl ?? "") < (rhs.bookUrl ?? "") : left < right
        }
        var attempts: [BookReadAttempt] = []
        var bestBook: ReadableBook?
        var bestContents: [ChapterContent] = []
        var requested = chapterLimit
        var seen = Set<String>()
        for item in candidates {
            try Task.checkCancellation()
            guard let candidate = Self.mapToFetchItem(item), seen.insert("\(item.sourceUrl ?? item.provider)|\(item.bookUrl ?? "")").inserted else { continue }
            do {
                let book = try await openBook(candidate)
                guard BookTitleNormalizer.normalize(book.name) == normalized,
                      author == nil || book.author?.trimmingCharacters(in: .whitespacesAndNewlines) == author?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    throw BookReadingError.empty("详情页书名或作者与请求不匹配")
                }
                if bestBook == nil { bestBook = book }
                let chapters = Array(book.chapters.filter { !$0.isVolume }.prefix(chapterLimit))
                var contents: [ChapterContent] = []
                for chapter in chapters {
                    do {
                        let content = try await fetchContent(book: book, chapter: chapter)
                        guard content.content.count >= max(1, minimumContentLength) else {
                            throw BookReadingError.empty("正文未达到最小长度 \(max(1, minimumContentLength))，可能为封面、提示或书评")
                        }
                        contents.append(content)
                    }
                    catch {
                        try Task.checkCancellation()
                        attempts.append(BookReadAttempt(sourceUrl: book.sourceUrl, bookUrl: book.bookUrl,
                            message: "\(chapter.title)：\(error.localizedDescription)"))
                    }
                }
                if contents.count == chapters.count && !contents.isEmpty {
                    return BookReadResponse(book: book, contents: contents, requestedChapters: chapters.count, complete: true, attempts: attempts)
                }
                if contents.count > bestContents.count {
                    bestBook = book; bestContents = contents; requested = chapters.count
                }
            } catch {
                try Task.checkCancellation()
                attempts.append(BookReadAttempt(sourceUrl: item.sourceUrl ?? item.provider, bookUrl: item.bookUrl, message: error.localizedDescription))
            }
        }
        if candidates.isEmpty {
            attempts.append(BookReadAttempt(sourceUrl: "", bookUrl: nil, message: "搜索预算内没有取得匹配书名和作者的候选；可能无结果、书源不可访问或搜索超时"))
        }
        return BookReadResponse(book: bestBook, contents: bestContents, requestedChapters: requested, complete: false, attempts: attempts)
    }

    private func readingSource(url: String?, name: String?) throws -> PaquBookSource {
        let matches = sources.filter { source in
            if let url { return source.bookSourceUrl == url }
            return source.bookSourceName == name
        }
        guard matches.count == 1, let source = matches.first else { throw BookReadingError.sourceNotFound(url ?? name ?? "") }
        return source
    }

    private func readingPipeline(_ source: PaquBookSource, variables: [String: String], maxPages: Int = 100) -> BookReadingPipeline {
        BookReadingPipeline(source: source, session: session, cookies: cookieStore,
                            limiter: rateLimiter, variables: variables, maxPages: maxPages)
    }

    /// 获取书籍详情页信息（书名、作者、简介、封面、目录 URL 等）。
    /// - Parameters:
    ///   - bookURL: 书籍详情页 URL（相对路径或绝对 URL）。
    ///   - sourceName: 书源名称（模糊匹配）。
    /// - Returns: 书籍详情，失败返回 nil。
    public func fetchBookInfo(bookURL: String, sourceName: String) async -> BookInfo? {
        guard let source = sources.first(where: {
            $0.bookSourceName.contains(sourceName) || sourceName.contains($0.bookSourceName)
        }) else { return nil }

        return await BookInfoFetcher.fetchInfo(
            bookURL: bookURL,
            source: source,
            session: session,
            cookieStore: cookieStore
        )
    }

    /// 获取书籍详情页信息（直接指定书源）。
    public func fetchBookInfo(bookURL: String, source: PaquBookSource) async -> BookInfo? {
        await BookInfoFetcher.fetchInfo(
            bookURL: bookURL,
            source: source,
            session: session,
            cookieStore: cookieStore
        )
    }

    // MARK: - 目录获取

    /// 获取书籍目录（章节列表）。
    /// - Parameters:
    ///   - tocURL: 目录页 URL（相对路径或绝对 URL）。
    ///   - sourceName: 书源名称（模糊匹配）。
    /// - Returns: 章节列表，按顺序排列。
    public func fetchToc(tocURL: String, sourceName: String) async -> [Chapter] {
        guard let source = sources.first(where: {
            $0.bookSourceName.contains(sourceName) || sourceName.contains($0.bookSourceName)
        }) else { return [] }

        return await TocFetcher.fetchToc(
            tocURL: tocURL,
            source: source,
            session: session,
            cookieStore: cookieStore
        )
    }

    /// 获取书籍目录（直接指定书源）。
    public func fetchToc(tocURL: String, source: PaquBookSource) async -> [Chapter] {
        await TocFetcher.fetchToc(
            tocURL: tocURL,
            source: source,
            session: session,
            cookieStore: cookieStore
        )
    }

    /// 逐源探针：返回每个书源对指定书名实际命中的结果数（用于诊断哪些源可用）。
    public struct SourceProbe: Sendable {
        public let name: String
        public let group: String?
        public let resultCount: Int
        public let error: String?
    }

    public func probe(bookName: String) async -> [SourceProbe] {
        let key = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        var out: [SourceProbe] = []
        for batch in sources.chunks(of: max(1, maxConcurrentSources)) {
            let batchResults = await withTaskGroup(of: SourceProbe.self) { group -> [SourceProbe] in
                for source in batch {
                    group.addTask {
                        let items = await BookSourceSearcher.search(source, key: key, page: 1, session: self.session, cookieStore: self.cookieStore)
                        return SourceProbe(
                            name: source.bookSourceName,
                            group: source.bookSourceGroup,
                            resultCount: items.count,
                            error: nil
                        )
                    }
                }
                var collected: [SourceProbe] = []
                for await probe in group {
                    collected.append(probe)
                }
                return collected
            }
            out.append(contentsOf: batchResults)
        }
        return out
    }

    /// 端到端诊断：对每个源执行 搜索→详情(简介)→目录 全链路，返回可读文本。
    /// 用于回答「当前有几个源可用、分别能出什么」这类问题。
    public func diagnose(bookName: String) async -> String {
        let key = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "空书名" }

        var lines: [String] = []
        for source in sources {
            let items = await BookSourceSearcher.search(source, key: key, page: 1, session: session, cookieStore: cookieStore)
            guard let first = items.first else {
                lines.append("✗ [\(source.bookSourceName)] 搜索 0 条")
                continue
            }
            var line = "✓ [\(source.bookSourceName)] 搜索 \(items.count) 条"

            if let bookUrl = first.bookUrl, !bookUrl.isEmpty {
                let info = await BookInfoFetcher.fetchInfo(bookURL: bookUrl, source: source, session: session, cookieStore: cookieStore)
                if let info {
                    if let intro = info.intro, !intro.isEmpty {
                        line += " | 简介 有(\(intro.count)字)"
                    } else {
                        line += " | 简介 无(源未配 intro 或解析空)"
                    }
                    // 目录：优先 tocUrl，为空时回退到 bookUrl（如望书阁目录直接内嵌详情页）
                    let tocURL = (info.tocUrl?.isEmpty == false) ? info.tocUrl! : bookUrl
                    let chapters = await TocFetcher.fetchToc(tocURL: tocURL, source: source, session: session, cookieStore: cookieStore)
                    line += " | 目录 \(chapters.count) 章"
                } else {
                    line += " | 详情解析失败(缺 init 处理?)"
                }
                line += " | bookUrl=\(bookUrl.prefix(80))"
            } else {
                line += " | 无 bookUrl"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 结构化审计结果：每个源一条，记录 搜索→简介→目录 三层数据与能力分级。
    public struct SourceAudit: Codable, Sendable {
        public let name: String
        public let group: String?
        public let url: String?
        public let searchCount: Int
        public let introLen: Int
        public let tocCount: Int
        /// 能力分级：4=全通(搜索+简介+目录) 3=搜索+简介 2=搜索+目录 1=仅搜索 0=不可用
        public let tier: Int
    }

    /// 全量审计：对每个源执行 搜索→详情(简介)→目录 全链路，返回结构化分层结果。
    /// 并发执行，用于批量评估源包可用性并按能力排序。
    public func audit(bookName: String) async -> [SourceAudit] {
        let key = bookName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }

        var out: [SourceAudit] = []
        for batch in sources.chunks(of: max(1, maxConcurrentSources)) {
            let batchResults = await withTaskGroup(of: SourceAudit.self) { group -> [SourceAudit] in
                for source in batch {
                    group.addTask {
                        let items = await BookSourceSearcher.search(source, key: key, page: 1, session: self.session, cookieStore: self.cookieStore)
                        let searchCount = items.count
                        guard let first = items.first, let bookUrl = first.bookUrl, !bookUrl.isEmpty else {
                            return SourceAudit(
                                name: source.bookSourceName, group: source.bookSourceGroup,
                                url: source.bookSourceUrl, searchCount: searchCount,
                                introLen: 0, tocCount: 0,
                                tier: searchCount > 0 ? 1 : 0
                            )
                        }

                        var introLen = 0
                        var tocCount = 0
                        if let info = await BookInfoFetcher.fetchInfo(bookURL: bookUrl, source: source, session: self.session, cookieStore: self.cookieStore) {
                            introLen = info.intro?.count ?? 0
                            let tocURL = (info.tocUrl?.isEmpty == false) ? info.tocUrl! : bookUrl
                            let chapters = await TocFetcher.fetchToc(tocURL: tocURL, source: source, session: self.session, cookieStore: self.cookieStore)
                            tocCount = chapters.count
                        }

                        var tier = 1
                        if introLen > 0 && tocCount > 0 { tier = 4 }
                        else if introLen > 0 { tier = 3 }
                        else if tocCount > 0 { tier = 2 }

                        return SourceAudit(
                            name: source.bookSourceName, group: source.bookSourceGroup,
                            url: source.bookSourceUrl, searchCount: searchCount,
                            introLen: introLen, tocCount: tocCount, tier: tier
                        )
                    }
                }
                var collected: [SourceAudit] = []
                for await a in group { collected.append(a) }
                return collected
            }
            out.append(contentsOf: batchResults)
        }
        return out
    }

    // MARK: - 并发搜索

    /// 并发搜索所有书源，采用「持续限流 + 时间预算 + 熔断 + tier 排序」四层调度：
    /// 1. 单一 TaskGroup 一次性放入全部源，信号量限制同时进行的请求数（做完一个补一个，
    ///    消除分批 barrier 的槽位空等）；
    /// 2. 可选 overallTimeout 到点取消未完成源，返回已收集的部分结果；
    /// 3. 熔断器跳过冷却中的失效源；
    /// 4. sources 已在 init 按 tier 降序排好，快源先被调度。
    private func searchAllSources(key: String, overallTimeout: TimeInterval? = nil) async -> [ParsedBookItem] {
        var collected: [ParsedBookItem] = []
        for await items in searchAllSourcesStream(key: key, overallTimeout: overallTimeout) {
            collected.append(contentsOf: items)
        }
        return collected
    }

    /// 流式并发搜索核心：每完成一个源就 yield 该源的原始解析结果批次（未跨源去重）。
    /// 调度策略与 `searchAllSources` 一致（信号量持续限流 + 熔断 + tier 排序），
    /// 到点取消未完成源，已完成的批次仍会 yield（部分结果语义）。调用方负责去重/过滤/排序。
    private func searchAllSourcesStream(key: String, overallTimeout: TimeInterval? = nil) -> AsyncStream<[ParsedBookItem]> {
        AsyncStream { continuation in
            guard !sources.isEmpty else {
                continuation.finish()
                return
            }

            let semaphore = AsyncSemaphore(permits: max(1, maxConcurrentSources))

            // 用 Task 包装：到点取消 work（取消会传播到 group 所有子任务，子任务快速退出），
            // 使 withTaskGroup 的 for await 消费完已完成的子任务后结束 → 返回部分结果。
            let work = Task {
                await withTaskGroup(of: [ParsedBookItem].self) { group in
                    for source in sources {
                        group.addTask {
                            let id = source.bookSourceName
                            // 熔断：冷却中的源直接跳过（快速路径，不占许可）
                            guard await self.breaker.allow(id) else { return [] }

                            // 持续限流：等待许可（任务取消时返回 nil）
                            guard let items: [ParsedBookItem] = await semaphore.withPermit({
                                if let host = source.host {
                                    await self.rateLimiter.waitIfNeeded(for: host)
                                }
                                let outcome = await BookSourceSearcher.searchWithOutcome(source, key: key, page: 1, session: self.session, cookieStore: self.cookieStore)
                                await self.breaker.record(id, failed: outcome.failed)
                                return outcome.items
                            }) else { return [] }

                            return Array(items.prefix(max(0, self.maxResultsPerSource)))
                        }
                    }

                    for await items in group {
                        if !items.isEmpty {
                            continuation.yield(items)
                        }
                    }
                }
                continuation.finish()
            }

            let deadline = Task {
                if let overallTimeout, overallTimeout > 0 {
                    try? await Task.sleep(for: .seconds(overallTimeout))
                    work.cancel()
                }
            }

            continuation.onTermination = { _ in
                work.cancel()
                deadline.cancel()
            }
        }
    }

    // MARK: - 合并去重

    private func mergeAndDedupe(_ items: [ParsedBookItem], key: String) -> [BookFetchItem] {
        let normalizedKey = BookTitleNormalizer.normalize(key)

        // 按归一化书名去重，保留信息最全的一条。
        var bestByTitle: [String: ParsedBookItem] = [:]
        var order: [String] = []

        for item in items {
            let normalized = BookTitleNormalizer.normalize(item.title ?? "")

            // 空书名（解析失败产生的脏数据）直接剔除，避免 `contains("")` 恒真导致放行空白项。
            guard !normalized.isEmpty else { continue }

            // 仅书名精确匹配：归一化书名必须与搜索词完全一致，不再考虑作者或其他筛选条件。
            guard normalized == normalizedKey else { continue }

            if let existing = bestByTitle[normalized] {
                if score(item) > score(existing) {
                    bestByTitle[normalized] = item
                }
            } else {
                bestByTitle[normalized] = item
                order.append(normalized)
            }
        }

        return order.compactMap { titleKey -> BookFetchItem? in
            guard let item = bestByTitle[titleKey] else { return nil }
            return Self.mapToFetchItem(item)
        }
    }

    /// 条目完整度打分：有封面/作者优先。
    private func score(_ item: ParsedBookItem) -> Int {
        var s = 0
        if !(item.coverUrl ?? "").isEmpty { s += 4 }
        if !(item.author ?? "").isEmpty { s += 2 }
        if !(item.intro ?? "").isEmpty { s += 1 }
        return s
    }
}

extension Array {
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
