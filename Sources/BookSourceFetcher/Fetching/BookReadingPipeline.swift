import Foundation
import SwiftSoup

/// A runtime per book operation. Variables are serialized between calls, never shared across books.
final class BookReadingPipeline {
    let source: PaquBookSource
    let session: URLSession
    let cookies: CookieStore
    let limiter: RateLimiter
    let runtime: JSRuntime
    let maxPages: Int

    init(source: PaquBookSource, session: URLSession, cookies: CookieStore,
         limiter: RateLimiter, variables: [String: String], maxPages: Int = 100) {
        self.source = source; self.session = session; self.cookies = cookies
        self.limiter = limiter; self.maxPages = max(1, maxPages)
        runtime = JSRuntime(cookieStore: cookies)
        runtime.setSourceHost(source.host ?? "")
        for (key, value) in variables { runtime.put(key, value) }
        if let library = source.jsLib { runtime.run(library, key: "", page: 1, baseURL: source.bookSourceUrl) }
    }

    struct Page { let text: String; let url: String }

    func setBook(_ book: ReadableBook) {
        runtime.setObject([
            "bookUrl": book.bookUrl, "tocUrl": book.tocUrl, "name": book.name,
            "author": book.author ?? "", "origin": book.sourceUrl
        ], forKeyedSubscript: "book")
        runtime.setObject(["bookSourceUrl": source.bookSourceUrl ?? "", "bookSourceName": source.bookSourceName], forKeyedSubscript: "source")
    }

    func request(_ raw: String, base: String, webJS: String? = nil) async throws -> Page {
        try Task.checkCancellation()
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@js:") {
            value = runtime.run(String(value.dropFirst(4)), key: "", page: 1, baseURL: base) ?? ""
        } else if value.hasPrefix("<js>"), value.hasSuffix("</js>") {
            value = runtime.run(String(value.dropFirst(4).dropLast(5)), key: "", page: 1, baseURL: base) ?? ""
        }
        if let regex = try? NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#) {
            for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                guard let expression = Range(match.range(at: 1), in: value), let range = Range(match.range, in: value) else { continue }
                let replacement = runtime.run(String(value[expression]), key: "", page: 1, baseURL: base) ?? ""
                value.replaceSubrange(range, with: replacement)
            }
        }
        var spec = SearchRequestBuilder.parseSearchUrl(value, runtime: runtime)
        spec.urlString = try absolute(spec.urlString, base: base)
        guard var req = SearchRequestBuilder.makeRequest(from: spec, source: source, cookieStore: cookies) else {
            throw BookReadingError.invalidURL(value)
        }
        req.timeoutInterval = session.configuration.timeoutIntervalForRequest
        await limiter.waitIfNeeded(for: source.host ?? "")
        try Task.checkCancellation()
        if spec.webView || webJS?.isEmpty == false {
            #if canImport(WebKit)
            let renderer = await MainActor.run { WebViewRenderer() }
            let text = await renderer.load(request: req, js: webJS, timeout: req.timeoutInterval)
            try Task.checkCancellation()
            guard let text else { throw BookReadingError.empty("WebView 正文响应") }
            let url = await renderer.finalURL?.absoluteString ?? spec.urlString
            return Page(text: text, url: url)
            #else
            throw BookReadingError.unsupported("当前平台没有 WebKit")
            #endif
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw BookReadingError.empty("HTTP 响应") }
        let finalURL = http.url ?? req.url!
        if source.isCookieJarEnabled { cookies.save(from: http, url: finalURL) }
        guard (200..<300).contains(http.statusCode) else { throw BookReadingError.http(http.statusCode, finalURL.absoluteString) }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        return Page(text: text, url: finalURL.absoluteString)
    }

    func absolute(_ raw: String, base: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: URL(string: base))?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw BookReadingError.invalidURL(raw)
        }
        return url.absoluteString
    }

    /// Preserve Legado URL options outside the URL instead of percent-encoding the JSON into its path.
    func link(_ raw: String, base: String) throws -> String {
        let spec = SearchRequestBuilder.parseSearchUrl(raw, runtime: runtime)
        let url = try absolute(spec.urlString, base: base)
        if let range = raw.range(of: spec.urlString), range.lowerBound == raw.startIndex {
            return url + raw[range.upperBound...]
        }
        return url
    }

    func context(_ page: Page) throws -> RuleContext {
        let object = try? JSONSerialization.jsonObject(with: Data(page.text.utf8), options: .fragmentsAllowed)
        let element = object == nil ? try SwiftSoup.parse(page.text) : nil
        runtime.setVariable("result", value: page.text)
        return RuleContext(baseURL: URL(string: page.url), element: element, json: object,
                           jsonRoot: object, variables: runtime.storage, runtime: runtime)
    }

    func value(_ rule: String?, _ context: RuleContext) -> String? {
        guard let result = RuleEngine.evaluate(rule, in: context)?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        return result
    }

    func links(_ rule: String?, _ context: RuleContext, base: String) throws -> [String] {
        guard let rule, !rule.isEmpty, let result = RuleEngine.parseRule(rule, in: context) else { return [] }
        let values: [String]
        switch result {
        case .json(let object):
            values = (object as? [Any])?.compactMap { JSONPath.stringify($0) } ?? [JSONPath.stringify(object) ?? ""]
        case .string(let string): values = string.components(separatedBy: .newlines)
        case .elements(let elements): values = try elements.map { try $0.attr("href") }
        case .none: values = []
        }
        return try values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { try link($0, base: base) }
    }

    func nodes(_ rule: String, _ ctx: RuleContext) -> [RuleContext] {
        if ctx.json != nil { return RuleEngine.evaluateJSONList(rule, in: ctx).map { ctx.scoped(toJSON: $0) } }
        return RuleEngine.evaluateElements(rule, in: ctx).map { ctx.scoped(to: $0) }
    }

    func resolve(_ initial: ReadableBook) async throws -> ReadableBook {
        var book = initial
        book.type = source.bookSourceType ?? 0
        setBook(book)
        var detail: Page?
        if let rule = source.ruleBookInfo {
            let page = try await request(book.bookUrl, base: source.bookSourceUrl ?? book.bookUrl)
            detail = page
            var ctx = try context(page)
            if let initialization = rule.`init`, !initialization.isEmpty,
               let result = RuleEngine.parseRule(initialization, in: ctx) {
                switch result {
                case .elements(let elements): ctx = ctx.scoped(to: elements.first)
                case .json(let json): ctx = ctx.scoped(toJSON: json)
                case .string(let string): ctx = try context(Page(text: string, url: page.url))
                case .none: break
                }
            }
            if book.name.isEmpty || rule.canReName != "false" {
                book.name = value(rule.name, ctx) ?? book.name
                book.author = value(rule.author, ctx) ?? book.author
            }
            book.intro = value(rule.intro, ctx).map { Self.format($0, base: page.url) } ?? book.intro
            book.kind = value(rule.kind, ctx) ?? book.kind
            book.wordCount = value(rule.wordCount, ctx) ?? book.wordCount
            book.latestChapterTitle = value(rule.lastChapter, ctx) ?? book.latestChapterTitle
            book.updateTime = value(rule.updateTime, ctx)
            book.downloadUrls = try links(rule.downloadUrls, ctx, base: page.url)
            if let cover = value(rule.coverUrl, ctx) { book.coverUrl = try link(cover, base: page.url) }
            if let toc = value(rule.tocUrl, ctx) { book.tocUrl = try link(toc, base: page.url) }
            else { book.tocUrl = page.url }
        }
        setBook(book)
        guard let rule = source.ruleToc, let list = rule.chapterList, !list.isEmpty else { throw BookReadingError.missingRule("ruleToc.chapterList") }
        if let js = rule.preUpdateJs { runtime.run(js, key: "", page: 1, baseURL: book.tocUrl) }
        var queue = [book.tocUrl]
        var visited = Set<String>()
        var identities = Set<String>()
        var chapters: [ReadableChapter] = []
        let reverse = list.hasPrefix("-")
        let selector = (list.hasPrefix("-") || list.hasPrefix("+")) ? String(list.dropFirst()) : list
        while !queue.isEmpty {
            try Task.checkCancellation()
            let url = queue.removeFirst()
            guard !visited.contains(url) else { continue }
            guard visited.count < maxPages else { throw BookReadingError.pageLimit(maxPages) }
            visited.insert(url)
            let page: Page
            if let detail, url == detail.url || url == initial.bookUrl { page = detail }
            else { page = try await request(url, base: book.bookUrl) }
            let ctx = try context(page)
            for item in nodes(selector, ctx) {
                guard let title = value(rule.chapterName, item) else { continue }
                let volume = Self.truth(value(rule.isVolume, item))
                let rawURL = value(rule.chapterUrl, item)
                guard volume || rawURL != nil else { continue }
                let chapterURL = try rawURL.map { try link($0, base: page.url) } ?? ""
                let identity = volume ? "volume:\(title):\(chapterURL)" : chapterURL
                guard identities.insert(identity).inserted else { continue }
                var chapter = ReadableChapter(index: chapters.count, title: title, url: chapterURL,
                    bookUrl: book.bookUrl, isVolume: volume, isVip: Self.truth(value(rule.isVip, item)),
                    isPay: Self.truth(value(rule.isPay, item)), tag: value(rule.updateTime, item), variables: runtime.storage)
                chapter.baseUrl = page.url
                chapters.append(chapter)
            }
            queue.append(contentsOf: try links(rule.nextTocUrl, ctx, base: page.url).filter { !visited.contains($0) })
        }
        if reverse { chapters.reverse() }
        for index in chapters.indices {
            chapters[index].index = index
            if let js = rule.formatJs {
                runtime.setVariable("result", value: chapters[index].title)
                runtime.setVariable("title", value: chapters[index].title)
                if let title = runtime.run(js, key: "", page: 1, baseURL: book.tocUrl), !title.isEmpty { chapters[index].title = title }
            }
        }
        guard chapters.contains(where: { !$0.isVolume }) else { throw BookReadingError.empty("目录") }
        book.chapters = chapters
        book.variables = runtime.storage
        return book
    }

    func content(book: ReadableBook, chapter: ReadableChapter) async throws -> ChapterContent {
        guard chapter.bookUrl == book.bookUrl else { throw BookReadingError.invalidURL("章节不属于当前书籍") }
        guard !chapter.isVolume else { return ChapterContent(chapter: chapter, content: chapter.tag ?? "", pageURLs: [], imageStyle: nil) }
        guard let rule = source.ruleContent, let selector = rule.content, !selector.isEmpty else { throw BookReadingError.missingRule("ruleContent.content") }
        if source.bookSourceType != nil && source.bookSourceType != 0 { throw BookReadingError.unsupported("非文本书源正文") }
        if rule.sourceRegex?.isEmpty == false { throw BookReadingError.unsupported("音视频资源嗅探 sourceRegex") }
        setBook(book)
        for (key, value) in chapter.variables { runtime.put(key, value) }
        runtime.setObject(["title": chapter.title, "url": chapter.url, "index": chapter.index] as [String: Any], forKeyedSubscript: "chapter")
        let next = book.chapters.first { $0.index > chapter.index && !$0.isVolume }?.url ?? ""
        runtime.setVariable("nextChapterUrl", value: next)
        var queue = [chapter.url]
        var visited = Set<String>()
        var pages: [String] = []
        var texts: [String] = []
        var updated = chapter
        while !queue.isEmpty {
            try Task.checkCancellation()
            let url = queue.removeFirst()
            guard url != next, !visited.contains(url) else { continue }
            guard pages.count < maxPages else { throw BookReadingError.pageLimit(maxPages) }
            visited.insert(url)
            let page = try await request(url, base: book.tocUrl, webJS: rule.webJs)
            // A pagination redirect into another chapter must never be appended.
            if !pages.isEmpty && page.url == next { break }
            if page.url != url && visited.contains(page.url) { continue }
            visited.insert(page.url)
            let ctx = try context(page)
            if pages.isEmpty, let title = value(rule.title, ctx) { updated.title = title }
            guard let raw = value(selector, ctx) else { throw BookReadingError.empty("正文 \(page.url)") }
            let formatted = Self.format(raw, base: page.url)
            guard !formatted.isEmpty else { throw BookReadingError.empty("正文 \(page.url)") }
            texts.append(formatted)
            pages.append(page.url)
            queue.append(contentsOf: try links(rule.nextContentUrl, ctx, base: page.url))
        }
        var result = texts.joined(separator: "\n")
        if let replace = rule.replaceRegex, !replace.isEmpty {
            if replace.hasPrefix("##") {
                let parts = replace.components(separatedBy: "##")
                var index = 1
                while index < parts.count {
                    let regex = try NSRegularExpression(pattern: parts[index])
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: index + 1 < parts.count ? parts[index + 1] : "")
                    index += 2
                }
            } else {
                let ctx = try context(Page(text: result, url: chapter.url))
                result = value(replace, ctx) ?? ""
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw BookReadingError.empty("净化后正文") }
        updated.variables = runtime.storage
        updated.wordCount = String(result.count)
        return ChapterContent(chapter: updated, content: result, pageURLs: pages, imageStyle: rule.imageStyle)
    }

    static func truth(_ value: String?) -> Bool {
        guard let value = value?.lowercased() else { return false }
        return !["", "false", "0", "null", "undefined"].contains(value)
    }

    static func format(_ html: String, base: String) -> String {
        guard let doc = try? SwiftSoup.parseBodyFragment(html) else { return html }
        _ = try? doc.select("script,style,noscript").remove()
        if let images = try? doc.select("img").array() {
            for image in images {
                let raw = ((try? image.attr("src")) ?? "").isEmpty ? ((try? image.attr("data-src")) ?? "") : ((try? image.attr("src")) ?? "")
                guard !raw.isEmpty, let url = URL(string: raw, relativeTo: URL(string: base))?.absoluteURL else { try? image.remove(); continue }
                let escaped = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                // Escape as text before stripping other markup.
                _ = try? image.before(TextNode("\n<img src=\"\(escaped)\">\n", ""))
                try? image.remove()
            }
        }
        if let breaks = try? doc.select("br,hr").array() {
            for element in breaks { _ = try? element.before(TextNode("\n", "")); try? element.remove() }
        }
        if let blocks = try? doc.select("p,div,h1,h2,h3,h4,li,section").array() {
            for element in blocks { _ = try? element.before(TextNode("\n", "")); _ = try? element.after(TextNode("\n", "")) }
        }
        func walk(_ node: Node) -> String {
            if let text = node as? TextNode { return text.getWholeText() }
            return node.getChildNodes().map(walk).joined()
        }
        return walk(doc).components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
