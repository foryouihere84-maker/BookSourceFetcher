//
//  SearchRequestBuilder.swift
//  BookSourceFetcher
//
//  解析书源的 searchUrl（支持 GET / POST / @js 动态签名 / 换行拼接 / cookie 指令），构建 URLRequest。
//

import Foundation

/// 解析后的搜索请求配置。
struct SearchRequestSpec: Sendable {
    var urlString: String
    var method: String          // "GET" / "POST"
    var body: String?           // POST body 模板
    var headers: [String: String]
    var webView: Bool = false   // 是否需用 webView 渲染（对应 {'webView': true}）
}

enum SearchRequestBuilder {

    /// 从书源 searchUrl 构建搜索请求配置。
    static func build(from source: PaquBookSource, key: String, page: Int, runtime: JSRuntime) -> SearchRequestSpec? {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else { return nil }

        let baseURL = source.bookSourceUrl ?? ""
        var spec: SearchRequestSpec

        let trimmed = stripDirectiveLines(from: searchUrl)

        if trimmed.hasPrefix("@js:") {
            // @js 动态 URL：执行 JS 得到 "URL,config" 形式
            let js = String(trimmed.dropFirst(4))
            guard let result = runtime.run(js, key: key, page: page, baseURL: baseURL) else { return nil }
            spec = parseSearchUrl(result, runtime: runtime)
            applyStoredHeaders(runtime, to: &spec)
        } else if trimmed.hasPrefix("<js>") {
            // <js>...</js> 动态 URL
            let body = String(trimmed.dropFirst(4))
            guard body.hasSuffix("</js>") else { return nil }
            let js = String(body.dropLast(5))
            guard let result = runtime.run(js, key: key, page: page, baseURL: baseURL) else { return nil }
            spec = parseSearchUrl(result, runtime: runtime)
            applyStoredHeaders(runtime, to: &spec)
        } else {
            spec = parseSearchUrl(trimmed, runtime: runtime)
        }

        // 展开模板变量 {{key}} / {{page}}
        spec.urlString = expand(spec.urlString, key: key, page: page, baseURL: baseURL)
        if let body = spec.body {
            spec.body = expand(body, key: key, page: page, baseURL: baseURL)
        }

        // 拼接相对 URL 与 baseURL
        spec.urlString = resolve(spec.urlString, baseURL: baseURL)
        guard !spec.urlString.isEmpty else { return nil }

        return spec
    }

    /// 把 @js 里 java.put("headers", ...) 存的 headers 应用到请求。
    private static func applyStoredHeaders(_ runtime: JSRuntime, to spec: inout SearchRequestSpec) {
        guard let headersStr = runtime.storage["headers"] else { return }
        guard let obj = runtime.parseObject(headersStr) else { return }
        if let headers = obj["headers"] as? [String: Any] {
            for (k, v) in headers { spec.headers[k] = "\(v)" }
        } else {
            for (k, v) in obj { spec.headers[k] = "\(v)" }
        }
    }

    // MARK: - searchUrl 解析

    /// searchUrl 可能包含多行（cookie 指令 + URL），也可能是 "url,{json配置}" 形式。
    static func parseSearchUrl(_ raw: String, runtime: JSRuntime) -> SearchRequestSpec {
        let combined = stripDirectiveLines(from: raw)
        guard !combined.isEmpty else {
            return SearchRequestSpec(urlString: "", method: "GET", body: nil, headers: [:])
        }

        // 处理 "url,{json配置}" 形式（含 ",{\"..." 转义）
        if let commaIdx = findConfigSeparator(in: combined) {
            let url = String(combined[..<commaIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let config = String(combined[combined.index(after: commaIdx)...])
            var spec = SearchRequestSpec(urlString: url, method: "GET", body: nil, headers: [:])
            applyConfig(config, to: &spec, runtime: runtime)
            return spec
        }

        // 无 config，去掉尾逗号（@js 返回 "URL," + java.put 空串时会残留）
        return SearchRequestSpec(urlString: stripTrailingComma(combined), method: "GET", body: nil, headers: [:])
    }

    /// Legado 允许在 URL 前放置 cookie/source 指令，配置对象也经常跨多行。
    /// 只移除整行指令，保留 URL 和配置对象的换行及字符串内容。
    private static func stripDirectiveLines(from raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .filter { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && !(value.hasPrefix("{{") && value.hasSuffix("}}"))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉字符串末尾的逗号与空白。
    private static func stripTrailingComma(_ s: String) -> String {
        var t = s
        while let last = t.last, last == "," || last == " " {
            t.removeLast()
        }
        return t
    }

    /// 找到 URL 与 config 的分隔逗号（config 以 { 或 "{" 开头）。
    private static func findConfigSeparator(in line: String) -> String.Index? {
        // 形如 "url,{...}" 或 "url,{\"...\"}"。查询参数本身可能含逗号，
        // 因此要找后续真正引出对象的逗号，而不是固定取第一个。
        var search = line.startIndex
        while let comma = line[search...].firstIndex(of: ",") {
            var idx = line.index(after: comma)
            while idx < line.endIndex, line[idx].isWhitespace || line[idx] == "\"" {
                idx = line.index(after: idx)
            }
            if idx < line.endIndex, line[idx] == "{" {
                return comma
            }
            guard idx < line.endIndex else { break }
            search = idx
        }
        return nil
    }

    /// 解析配置里的 method / body / headers（用 JS 引擎，兼容单引号）。
    private static func applyConfig(_ config: String, to spec: inout SearchRequestSpec, runtime: JSRuntime) {
        var cfg = config.trimmingCharacters(in: .whitespacesAndNewlines)
        // 处理 \n 与 \" 转义
        cfg = cfg.replacingOccurrences(of: "\\n", with: "\n")
        cfg = cfg.replacingOccurrences(of: "\\\"", with: "\"")

        guard let obj = runtime.parseObject(cfg) else { return }
        if let method = obj["method"] as? String {
            spec.method = method.uppercased()
        }
        if let body = obj["body"] as? String {
            spec.body = body
        }
        if let headers = obj["headers"] as? [String: Any] {
            for (k, v) in headers { spec.headers[k] = "\(v)" }
        }
        // webView 标记（Legado：{'webView': true} 表示该请求需真实浏览器渲染）
        if let webView = obj["webView"] as? Bool {
            spec.webView = webView
        } else if let webViewStr = obj["webView"] as? String {
            spec.webView = (webViewStr == "true" || webViewStr == "1")
        }
    }

    // MARK: - 模板展开

    private static func expand(_ s: String, key: String, page: Int, baseURL: String) -> String {
        var result = s
        let encodedKey = encodeQueryValue(key)
        let replacements: [(String, String)] = [
            ("{{key}}", encodedKey),
            ("{{page}}", "\(page)"),
            ("{{page-1}}", "\(page - 1)"),
            ("{{page+1}}", "\(page + 1)")
        ]
        for (token, value) in replacements {
            result = result.replacingOccurrences(of: token, with: value)
        }
        // 剩余的 {{...}} 模板（cookie/source 等）清空
        if result.contains("{{") {
            result = result.replacingOccurrences(
                of: #"\{\{.*?\}\}"#, with: "", options: .regularExpression
            )
        }
        return result
    }

    private static func resolve(_ urlString: String, baseURL: String) -> String {
        let url = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // 已是绝对 URL
        if url.hasPrefix("http://") || url.hasPrefix("https://") {
            return url
        }
        guard !baseURL.isEmpty else { return url }
        if let base = URL(string: baseURL), let resolved = URL(string: url, relativeTo: base)?.absoluteURL {
            return resolved.absoluteString
        }
        return url
    }

    private static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=#?%+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 构建 URLRequest

    static func makeRequest(from spec: SearchRequestSpec, source: PaquBookSource, cookieStore: CookieStore? = nil) -> URLRequest? {
        guard let url = URL(string: spec.urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = spec.method

        if spec.method == "POST" {
            if let body = spec.body {
                request.httpBody = body.data(using: .utf8)
            }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        // 书源 header（可能是 JSON 字符串）
        if let headerStr = source.header, !headerStr.isEmpty {
            let headers = parseHeader(headerStr)
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
        // 配置里的 headers 优先
        for (k, v) in spec.headers {
            request.setValue(v, forHTTPHeaderField: k)
        }

        // Layer 3 CookieJar：请求前回传该域名 Cookie（对应 Legado enabledCookieJar）
        if source.isCookieJarEnabled, let cookieStore {
            if let cookie = cookieStore.cookie(for: url) {
                let existing = request.value(forHTTPHeaderField: "Cookie")
                if let merged = CookieStore.mergeCookies(existing, cookie) {
                    request.setValue(merged, forHTTPHeaderField: "Cookie")
                }
            }
        }

        // 模拟浏览器 UA
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
        for (k, v) in obj {
            result[k] = "\(v)"
        }
        return result
    }
}
