//
//  TocFetcher.swift
//  BookSourceFetcher
//
//  从书源的 ruleToc 规则获取书籍目录（章节列表）。
//  支持翻页：当规则返回 nextTocUrl 时自动请求下一页。
//

import Foundation
import SwiftSoup

enum TocFetcher {

    /// 目录获取的最大翻页次数（防止死循环）。
    private static let maxPages = 50

    /// 获取书籍目录。
    /// - Parameters:
    ///   - tocURL: 目录页 URL（相对或绝对均可）。
    ///   - source: 书源（提供 ruleToc + header + cookie 配置）。
    ///   - session: URLSession。
    ///   - cookieStore: 共享 Cookie 存储。
    /// - Returns: 章节列表，按顺序排列。
    static func fetchToc(
        tocURL: String,
        source: PaquBookSource,
        session: URLSession,
        cookieStore: CookieStore
    ) async -> [Chapter] {
        guard let rule = source.ruleToc, let rawChapterListRule = rule.chapterList, !rawChapterListRule.isEmpty else {
            return []
        }

        // 解析 chapterList 前缀：`-` = 倒序，`+` = 正序（默认）
        let (chapterListRule, shouldReverse) = parseChapterListPrefix(rawChapterListRule)

        var allChapters: [Chapter] = []
        var currentURL = tocURL

        for _ in 0..<maxPages {
            guard !currentURL.isEmpty else { break }

            let absoluteURL = resolveURL(currentURL, baseURL: source.bookSourceUrl ?? "")
            guard let url = URL(string: absoluteURL) else { break }

            // 登录态检查
            switch LoginGate.check(source: source, cookieStore: cookieStore) {
            case .requiresLogin: break
            default: break
            }

            // 构建请求
            guard let request = buildRequest(url: url, source: source, cookieStore: cookieStore) else {
                break
            }

            // 发送请求
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                break
            }

            // 保存 Set-Cookie
            if source.isCookieJarEnabled {
                cookieStore.save(from: http, url: url)
            }

            // 解码响应
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            // 解析
            var chapters: [Chapter] = []
            var nextURL: String? = nil

            if isJSON(text) {
                // 相对章节链接和下一页链接应相对于本次实际请求 URL 解析，
                // 不能退回书源根地址（详情页通常位于多级路径下）。
                let result = parseJSON(text: text, rule: rule, chapterListRule: chapterListRule, baseURL: absoluteURL)
                chapters = result.chapters
                nextURL = result.nextURL
            } else {
                let result = parseHTML(text: text, rule: rule, chapterListRule: chapterListRule, baseURL: absoluteURL)
                chapters = result.chapters
                nextURL = result.nextURL
            }

            allChapters.append(contentsOf: chapters)

            // 翻页：有 nextTocUrl 才继续
            if let next = nextURL, !next.isEmpty, next != currentURL {
                currentURL = next
            } else {
                break
            }
        }

        // 倒序处理
        if shouldReverse {
            allChapters.reverse()
        }

        // formatJs 后处理章节名
        if let formatJs = rule.formatJs, !formatJs.isEmpty {
            allChapters = applyFormatJs(allChapters, js: formatJs)
        }

        return allChapters
    }

    /// 解析 chapterList 前缀：`-` = 倒序，`+` = 正序。返回 (实际规则, 是否倒序)。
    private static func parseChapterListPrefix(_ rule: String) -> (rule: String, shouldReverse: Bool) {
        var r = rule
        var reverse = false
        if r.hasPrefix("-") {
            reverse = true
            r = String(r.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if r.hasPrefix("+") {
            r = String(r.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (r, reverse)
    }

    /// 对章节名执行 formatJs 后处理。JS 里通过 `result` 变量传入章节名，返回处理后的名字。
    private static func applyFormatJs(_ chapters: [Chapter], js: String) -> [Chapter] {
        let runtime = JSRuntime()
        return chapters.map { ch in
            runtime.put("title", ch.name)
            let result = runtime.run(js, key: ch.name, page: 1, baseURL: nil)
            let newName = (result ?? ch.name).trimmingCharacters(in: .whitespacesAndNewlines)
            return Chapter(name: newName.isEmpty ? ch.name : newName, url: ch.url, updateTime: ch.updateTime)
        }
    }

    // MARK: - 解析结果

    private struct ParseResult {
        let chapters: [Chapter]
        let nextURL: String?
    }

    // MARK: - JSON 解析

    private static func parseJSON(text: String, rule: TocRule, chapterListRule: String, baseURL: String?) -> ParseResult {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return ParseResult(chapters: [], nextURL: nil)
        }

        let context = RuleContext(key: "", page: 1, baseURL: baseURL.flatMap { URL(string: $0) }, element: nil, json: root, jsonRoot: root)

        // chapterList 规则返回章节列表（JSON 数组）
        let items = RuleEngine.evaluateJSONList(chapterListRule, in: context)
        let chapters = items.compactMap { item -> Chapter? in
            let itemCtx = RuleContext(key: "", page: 1, baseURL: context.baseURL, element: nil, json: item, jsonRoot: root)

            let name = RuleEngine.evaluate(rule.chapterName, in: itemCtx)
            let url = resolveURL(RuleEngine.evaluate(rule.chapterUrl, in: itemCtx), baseURL: context.baseURL)
            let updateTime = rule.updateTime.flatMap { RuleEngine.evaluate($0, in: itemCtx) }

            guard let name, !name.isEmpty, let url, !url.isEmpty else { return nil }
            return Chapter(name: name, url: url, updateTime: updateTime)
        }

        // nextTocUrl（翻页）
        let nextURL = rule.nextTocUrl
            .flatMap { RuleEngine.evaluate($0, in: context) }
            .flatMap { resolveURL($0, baseURL: context.baseURL) }

        return ParseResult(chapters: chapters, nextURL: nextURL)
    }

    // MARK: - HTML 解析

    private static func parseHTML(text: String, rule: TocRule, chapterListRule: String, baseURL: String?) -> ParseResult {
        guard let document = try? SwiftSoup.parse(text) else {
            return ParseResult(chapters: [], nextURL: nil)
        }

        let context = RuleContext(key: "", page: 1, baseURL: baseURL.flatMap { URL(string: $0) }, element: document, json: nil, jsonRoot: nil)

        // chapterList 规则返回章节元素列表
        let elements = RuleEngine.evaluateElements(chapterListRule, in: context)
        let chapters = elements.compactMap { element -> Chapter? in
            let itemCtx = context.scoped(to: element)

            let name = RuleEngine.evaluate(rule.chapterName, in: itemCtx)
            let url = resolveURL(RuleEngine.evaluate(rule.chapterUrl, in: itemCtx), baseURL: context.baseURL)
            let updateTime = rule.updateTime.flatMap { RuleEngine.evaluate($0, in: itemCtx) }

            guard let name, !name.isEmpty, let url, !url.isEmpty else { return nil }
            return Chapter(name: name, url: url, updateTime: updateTime)
        }

        // nextTocUrl（翻页）
        let nextURL = rule.nextTocUrl
            .flatMap { RuleEngine.evaluate($0, in: context) }
            .flatMap { resolveURL($0, baseURL: context.baseURL) }

        return ParseResult(chapters: chapters, nextURL: nextURL)
    }

    // MARK: - 工具

    private static func isJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return false }
        return first == "{" || first == "["
    }

    private static func resolveURL(_ urlString: String, baseURL: String) -> String {
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else { return url }
        if let base = URL(string: baseURL), let resolved = URL(string: url, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return url
    }

    private static func resolveURL(_ value: String?, baseURL: URL?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let baseURL else { return trimmed }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString ?? trimmed
    }

    private static func buildRequest(url: URL, source: PaquBookSource, cookieStore: CookieStore) -> URLRequest? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let headerStr = source.header, !headerStr.isEmpty {
            let headers = parseHeader(headerStr)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        }

        if source.isCookieJarEnabled, let cookie = cookieStore.cookie(for: url) {
            let existing = request.value(forHTTPHeaderField: "Cookie")
            if let merged = CookieStore.mergeCookies(existing, cookie) {
                request.setValue(merged, forHTTPHeaderField: "Cookie")
            }
        }

        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        return request
    }

    private static func parseHeader(_ header: String) -> [String: String] {
        var h = header.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.replacingOccurrences(of: "\\n", with: "\n")
        guard let data = h.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: String] = [:]
        for (k, v) in obj { result[k] = "\(v)" }
        return result
    }
}
