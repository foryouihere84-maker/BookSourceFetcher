//
//  BookInfoFetcher.swift
//  BookSourceFetcher
//
//  从书源的 ruleBookInfo 规则获取书籍详情页信息（书名、作者、简介、封面、目录 URL 等）。
//

import Foundation
import SwiftSoup

enum BookInfoFetcher {

    /// 获取书籍详情页信息。
    /// - Parameters:
    ///   - bookURL: 书籍详情页 URL（相对或绝对均可）。
    ///   - source: 书源（提供 ruleBookInfo + header + cookie 配置）。
    ///   - session: URLSession。
    ///   - cookieStore: 共享 Cookie 存储。
    /// - Returns: 解析后的 BookInfo，失败返回 nil。
    static func fetchInfo(
        bookURL: String,
        source: PaquBookSource,
        session: URLSession,
        cookieStore: CookieStore
    ) async -> BookInfo? {
        guard let rule = source.ruleBookInfo else { return nil }

        // 解析为绝对 URL
        let absoluteURL = resolveURL(bookURL, baseURL: source.bookSourceUrl ?? "")
        guard !absoluteURL.isEmpty, let url = URL(string: absoluteURL) else { return nil }

        // 登录态检查
        switch LoginGate.check(source: source, cookieStore: cookieStore) {
        case .requiresLogin: return nil
        default: break
        }

        // 构建请求
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // 书源 header
        if let headerStr = source.header, !headerStr.isEmpty {
            let headers = parseHeader(headerStr)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        }

        // Cookie
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

        // 发送请求
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
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
        if isJSON(text) {
            return parseJSON(text: text, rule: rule, source: source, bookURL: absoluteURL, cookieStore: cookieStore)
        } else {
            return parseHTML(text: text, rule: rule, source: source, bookURL: absoluteURL, cookieStore: cookieStore)
        }
    }

    // MARK: - JSON 解析

    private static func parseJSON(text: String, rule: BookInfoRule, source: PaquBookSource, bookURL: String, cookieStore: CookieStore) -> BookInfo? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        // 执行 init 规则：先用 init 提取子对象，再在子对象上提取各字段
        // Legado 惯例：init = "$.data" → 先取 root.data，后续字段在此基础上解析
        var contextRoot: Any = root
        if let initRule = rule.`init`, !initRule.isEmpty {
            let initCtx = RuleContext(key: "", page: 1, baseURL: URL(string: bookURL), element: nil, json: root, jsonRoot: root)
            if let extracted = RuleEngine.evaluate(initRule, in: initCtx) {
                // 尝试将字符串反序列化为 JSON 对象
                if let extractedData = extracted.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: extractedData) {
                    contextRoot = obj
                }
            } else {
                // init 规则可能返回 JSON 对象（非字符串）
                let initResult = RuleEngine.parseRule(initRule, in: initCtx)
                if case .json(let v) = initResult, let v {
                    contextRoot = v
                }
            }
        }

        let context = RuleContext(key: "", page: 1, baseURL: URL(string: bookURL), element: nil, json: contextRoot, jsonRoot: root)

        let name = RuleEngine.evaluate(rule.name, in: context)
        let author = RuleEngine.evaluate(rule.author, in: context)
        var coverUrl = resolveURL(RuleEngine.evaluate(rule.coverUrl, in: context), baseURL: URL(string: bookURL))
        let intro = RuleEngine.evaluate(rule.intro, in: context)
        let tocUrl = resolveURL(RuleEngine.evaluate(rule.tocUrl, in: context), baseURL: URL(string: bookURL))
        let kind = RuleEngine.evaluate(rule.kind, in: context)
        let wordCount = RuleEngine.evaluate(rule.wordCount, in: context)
        let lastChapter = RuleEngine.evaluate(rule.lastChapter, in: context)

        // 封面解密
        if let js = source.coverDecodeJs, let rawCover = coverUrl, !rawCover.isEmpty {
            coverUrl = CoverDecryptor.decrypt(rawCover, js: js, source: source, cookieStore: cookieStore, bookURL: bookURL)
        }

        // 至少要有 name 或 intro 才算有效
        guard (name != nil && !(name ?? "").isEmpty) || (intro != nil && !(intro ?? "").isEmpty) else {
            return nil
        }

        return BookInfo(
            name: name,
            author: author,
            coverUrl: coverUrl,
            intro: intro,
            tocUrl: tocUrl,
            kind: kind,
            wordCount: wordCount,
            lastChapter: lastChapter
        )
    }

    // MARK: - HTML 解析

    private static func parseHTML(text: String, rule: BookInfoRule, source: PaquBookSource, bookURL: String, cookieStore: CookieStore) -> BookInfo? {
        guard let document = try? SwiftSoup.parse(text) else { return nil }

        let context = RuleContext(key: "", page: 1, baseURL: URL(string: bookURL), element: document, json: nil, jsonRoot: nil)

        let name = RuleEngine.evaluate(rule.name, in: context)
        let author = RuleEngine.evaluate(rule.author, in: context)
        var coverUrl = resolveURL(RuleEngine.evaluate(rule.coverUrl, in: context), baseURL: URL(string: bookURL))
        let intro = RuleEngine.evaluate(rule.intro, in: context)
        let tocUrl = resolveURL(RuleEngine.evaluate(rule.tocUrl, in: context), baseURL: URL(string: bookURL))
        let kind = RuleEngine.evaluate(rule.kind, in: context)
        let wordCount = RuleEngine.evaluate(rule.wordCount, in: context)
        let lastChapter = RuleEngine.evaluate(rule.lastChapter, in: context)

        // 封面解密
        if let js = source.coverDecodeJs, let rawCover = coverUrl, !rawCover.isEmpty {
            coverUrl = CoverDecryptor.decrypt(rawCover, js: js, source: source, cookieStore: cookieStore, bookURL: bookURL)
        }

        guard (name != nil && !(name ?? "").isEmpty) || (intro != nil && !(intro ?? "").isEmpty) else {
            return nil
        }

        return BookInfo(
            name: clean(name),
            author: clean(author),
            coverUrl: clean(coverUrl),
            intro: clean(intro),
            tocUrl: clean(tocUrl),
            kind: clean(kind),
            wordCount: clean(wordCount),
            lastChapter: clean(lastChapter)
        )
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

    private static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
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
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString ?? trimmed
    }
}
