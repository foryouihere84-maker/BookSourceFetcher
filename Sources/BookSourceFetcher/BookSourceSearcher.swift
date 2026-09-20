//
//  BookSourceSearcher.swift
//  BookSourceFetcher
//
//  对单个书源执行搜索：构建请求 → 请求 → 解析 HTML/JSON → 提取书籍条目。
//

import Foundation
import SwiftSoup

enum BookSourceSearcher {

    /// 单源搜索结果 + 失败标记。
    struct SearchOutcome {
        let items: [ParsedBookItem]
        /// true = 源级失败（需登录/请求构建失败/网络错误/非200/WebView 失败），应计入熔断；
        /// false = 请求成功（可能解析出 0 条，这是正常的"无结果"，不计熔断）。
        let failed: Bool
    }

    /// 搜索单个书源，返回解析出的书籍条目列表（兼容旧调用点）。
    static func search(_ source: PaquBookSource, key: String, page: Int, session: URLSession, cookieStore: CookieStore) async -> [ParsedBookItem] {
        await searchWithOutcome(source, key: key, page: page, session: session, cookieStore: cookieStore).items
    }

    /// 搜索单个书源，返回结果 + 失败标记（供熔断精确计数）。
    static func searchWithOutcome(_ source: PaquBookSource, key: String, page: Int, session: URLSession, cookieStore: CookieStore) async -> SearchOutcome {
        // Layer 3 登录态：loginUrl 非空时先判断是否已登录
        switch LoginGate.check(source: source, cookieStore: cookieStore) {
        case .requiresLogin:
            return SearchOutcome(items: [], failed: true)
        default:
            break
        }

        let runtime = JSRuntime(cookieStore: cookieStore)
        runtime.setSourceHost(source.host ?? "")
        guard let spec = SearchRequestBuilder.build(from: source, key: key, page: page, runtime: runtime) else {
            return SearchOutcome(items: [], failed: true)
        }

        // Layer 4 真实浏览器：searchUrl 带 {'webView': true} 时，用 WKWebView 渲染后解析
        if spec.webView {
            return await searchViaWebView(spec: spec, source: source, key: key, page: page)
        }

        guard let request = SearchRequestBuilder.makeRequest(from: spec, source: source, cookieStore: cookieStore) else {
            return SearchOutcome(items: [], failed: true)
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return SearchOutcome(items: [], failed: true)
        }

        // Layer 3 CookieJar：保存响应的 Set-Cookie
        if source.isCookieJarEnabled, let url = request.url {
            cookieStore.save(from: http, url: url)
        }

        return SearchOutcome(items: parse(data: data, source: source, key: key, page: page, baseURL: spec.urlString, cookieStore: cookieStore, runtime: runtime), failed: false)
    }

    /// Layer 4：用 WebView 加载渲染，取渲染后 HTML 再解析。
    private static func searchViaWebView(spec: SearchRequestSpec, source: PaquBookSource, key: String, page: Int) async -> SearchOutcome {
        #if canImport(WebKit)
        // 从 bookList 规则提取 CSS 选择器作为等待条件（SPA 异步渲染，如 ".qm-pic-txt@li" -> ".qm-pic-txt"）
        var waitFor: String? = nil
        if let bookList = source.ruleSearch?.bookList, !bookList.isEmpty {
            let selector = bookList.components(separatedBy: "@").first ?? ""
            let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                waitFor = trimmed
            }
        }
        let renderer = await MainActor.run { WebViewRenderer() }
        let html = await renderer.loadHTML(url: spec.urlString, waitForSelector: waitFor)
        guard let html, !html.isEmpty else { return SearchOutcome(items: [], failed: true) }
        let items = parse(data: Data(html.utf8), source: source, key: key, page: page, baseURL: spec.urlString, cookieStore: nil, runtime: nil)
        return SearchOutcome(items: items, failed: false)
        #else
        return SearchOutcome(items: [], failed: true)
        #endif
    }

    /// 解析响应数据。
    static func parse(data: Data, source: PaquBookSource, key: String, page: Int, baseURL: String?, cookieStore: CookieStore? = nil, runtime: JSRuntime? = nil) -> [ParsedBookItem] {
        guard let rule = source.ruleSearch else { return [] }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        let base = baseURL.flatMap { URL(string: $0) }

        // 判断 JSON 还是 HTML
        if isJSON(text) {
            return parseJSON(text: text, rule: rule, source: source, key: key, page: page, baseURL: base, cookieStore: cookieStore, runtime: runtime)
        } else {
            return parseHTML(text: text, rule: rule, source: source, key: key, page: page, baseURL: base, cookieStore: cookieStore, runtime: runtime)
        }
    }

    private static func isJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return first == "{" || first == "["
    }

    // MARK: - JSON 解析

    private static func parseJSON(text: String, rule: SearchRule, source: PaquBookSource, key: String, page: Int, baseURL: URL?, cookieStore: CookieStore?, runtime: JSRuntime? = nil) -> [ParsedBookItem] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let context = RuleContext(key: key, page: page, baseURL: baseURL, element: nil, json: root, jsonRoot: root, runtime: runtime)

        // bookList 规则（JSONPath）
        let items = RuleEngine.evaluateJSONList(rule.bookList, in: context)
        guard !items.isEmpty else { return [] }

        var results: [ParsedBookItem] = []
        for item in items {
            let itemCtx = RuleContext(key: key, page: page, baseURL: baseURL, element: nil, json: item, jsonRoot: root, runtime: runtime)
            let title = RuleEngine.evaluate(rule.name, in: itemCtx)
            let author = RuleEngine.evaluate(rule.author, in: itemCtx)
            var cover = RuleEngine.evaluate(rule.coverUrl, in: itemCtx)
            let bookURL = resolveURL(RuleEngine.evaluate(rule.bookUrl, in: itemCtx), baseURL: baseURL)
            cover = resolveURL(cover, baseURL: baseURL)

            // 封面解密：coverDecodeJs 非空时对封面 URL 做 JS 解密
            if let js = source.coverDecodeJs, let rawCover = cover, !rawCover.isEmpty {
                cover = CoverDecryptor.decrypt(rawCover, js: js, source: source, cookieStore: cookieStore, bookURL: bookURL)
            }

            let parsed = ParsedBookItem(
                title: clean(title),
                author: clean(author),
                coverUrl: clean(cover),
                bookUrl: clean(bookURL),
                intro: clean(RuleEngine.evaluate(rule.intro, in: itemCtx)),
                provider: source.bookSourceName
            )
            if parsed.isValid {
                results.append(parsed)
            }
        }
        return results
    }

    // MARK: - HTML 解析

    private static func parseHTML(text: String, rule: SearchRule, source: PaquBookSource, key: String, page: Int, baseURL: URL?, cookieStore: CookieStore?, runtime: JSRuntime? = nil) -> [ParsedBookItem] {
        guard let document = try? SwiftSoup.parse(text) else { return [] }

        let context = RuleContext(key: key, page: page, baseURL: baseURL, element: document, json: nil, jsonRoot: nil, runtime: runtime)

        // bookList 规则（CSS 选择器）
        let elements = RuleEngine.evaluateElements(rule.bookList, in: context)
        guard !elements.isEmpty else { return [] }

        var results: [ParsedBookItem] = []
        for element in elements {
            let itemCtx = context.scoped(to: element)
            let title = RuleEngine.evaluate(rule.name, in: itemCtx)
            let author = RuleEngine.evaluate(rule.author, in: itemCtx)
            var cover = RuleEngine.evaluate(rule.coverUrl, in: itemCtx)
            let bookURL = resolveURL(RuleEngine.evaluate(rule.bookUrl, in: itemCtx), baseURL: baseURL)
            cover = resolveURL(cover, baseURL: baseURL)

            // 封面解密：coverDecodeJs 非空时对封面 URL 做 JS 解密
            if let js = source.coverDecodeJs, let rawCover = cover, !rawCover.isEmpty {
                cover = CoverDecryptor.decrypt(rawCover, js: js, source: source, cookieStore: cookieStore, bookURL: bookURL)
            }

            let parsed = ParsedBookItem(
                title: clean(title),
                author: clean(author),
                coverUrl: clean(cover),
                bookUrl: clean(bookURL),
                intro: clean(RuleEngine.evaluate(rule.intro, in: itemCtx)),
                provider: source.bookSourceName
            )
            if parsed.isValid {
                results.append(parsed)
            }
        }
        return results
    }

    // MARK: - 清理

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // 去除书名字符串里常见的 HTML 残留
        let cleaned = trimmed
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func resolveURL(_ value: String?, baseURL: URL?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let baseURL else { return trimmed }
        if let absolute = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
            return absolute.absoluteString
        }
        return trimmed
    }
}
