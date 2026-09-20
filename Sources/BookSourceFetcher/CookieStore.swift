//
//  CookieStore.swift
//  BookSourceFetcher
//
//  按域名管理 Cookie 的线程安全容器。
//  对应 Legado 的 CookieManager / CookieStore 语义：
//    - enabledCookieJar=true 时，请求前从 store 回传该域名 Cookie，
//      响应后从 Set-Cookie 提取并保存（session 与持久 cookie 合并）。
//    - 支持外部注入登录后的 Cookie 字符串（爬虫无 UI 登录，替代 webView 登录）。
//

import Foundation

/// 线程安全的 Cookie 容器。key 为域名（host），value 为 "name=value; name2=value2"。
public final class CookieStore: @unchecked Sendable {

    private let lock = NSLock()
    private var store: [String: String] = [:]

    public init() {}

    // MARK: - 读取

    /// 取某个 URL 应回传的 Cookie 字符串（精确 host 匹配，回退父域）。
    public func cookie(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return cookie(forHost: host)
    }

    /// 取某个 host 应回传的 Cookie 字符串。
    public func cookie(forHost host: String) -> String? {
        let h = normalizeHost(host)
        lock.lock(); defer { lock.unlock() }
        return cookieLocked(forHost: h)
    }

    private func cookieLocked(forHost host: String) -> String? {
        // 1. 精确匹配
        if let c = store[host], !c.isEmpty { return c }
        // 2. 父域回退：去掉最左一段（如 api-bc.wtzw.com -> wtzw.com）
        let parts = host.components(separatedBy: ".")
        if parts.count > 2 {
            let parent = parts.dropFirst().joined(separator: ".")
            if let c = store[parent], !c.isEmpty { return c }
        }
        return nil
    }

    /// 判断某域名是否有已保存的 Cookie（用于登录态判断辅助）。
    public func hasCookie(forHost host: String) -> Bool {
        let h = normalizeHost(host)
        lock.lock(); defer { lock.unlock() }
        return cookieLocked(forHost: h) != nil
    }

    // MARK: - 保存

    /// 从响应头里提取 Set-Cookie 并保存（按响应 URL 的 host）。
    public func save(from response: HTTPURLResponse, url: URL) {
        guard let host = url.host?.lowercased() else { return }
        let headerFields = response.allHeaderFields as? [String: String] ?? [:]
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        guard !cookies.isEmpty else { return }

        var pairs: [String] = []
        for c in cookies {
            guard !c.name.isEmpty else { continue }
            pairs.append("\(c.name)=\(c.value)")
        }
        guard !pairs.isEmpty else { return }
        merge(cookieString: pairs.joined(separator: "; "), forHost: host)
    }

    /// 合并一段 Cookie 字符串到某 host（同 key 覆盖）。
    public func merge(cookieString: String, forHost host: String) {
        let h = normalizeHost(host)
        lock.lock(); defer { lock.unlock() }

        var map = Self.cookieToMap(store[h] ?? "")
        let newMap = Self.cookieToMap(cookieString)
        for (k, v) in newMap { map[k] = v }

        let merged = map.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        if merged.isEmpty {
            store.removeValue(forKey: h)
        } else {
            store[h] = merged
        }
    }

    /// 外部注入登录后的 Cookie（爬虫替代 webView 登录）。
    public func inject(cookieString: String, forHost host: String) {
        merge(cookieString: cookieString, forHost: host)
    }

    /// 清空某个 host 的 Cookie。
    public func remove(forHost host: String) {
        let h = normalizeHost(host)
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: h)
    }

    /// 清空全部 Cookie。
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }

    /// 当前存储的所有域名（用于调试）。
    public var allHosts: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(store.keys).sorted()
    }

    // MARK: - 工具

    /// 合并两段 Cookie 字符串，后者覆盖前者同 key 项。
    static func mergeCookies(_ a: String?, _ b: String?) -> String? {
        var map: [String: String] = [:]
        if let a { for (k, v) in cookieToMap(a) { map[k] = v } }
        if let b { for (k, v) in cookieToMap(b) { map[k] = v } }
        guard !map.isEmpty else { return nil }
        return map.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// 解析 "k=v; k2=v2" 为字典。
    static func cookieToMap(_ s: String) -> [String: String] {
        var map: [String: String] = [:]
        for part in s.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            map[key] = value
        }
        return map
    }

    private func normalizeHost(_ host: String) -> String {
        var h = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉端口
        if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
        return h
    }
}
