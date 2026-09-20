//
//  LoginGate.swift
//  BookSourceFetcher
//
//  登录态判断（Legado Layer 3 登录态）。
//  对应 Legado 的 loginUrl + loginCheckJs 语义：
//    - loginUrl 非空 → 书源需要登录
//    - 请求前执行 loginCheckJs，返回 true/false 判断是否已登录
//    - 已登录（或注入了有效 Cookie）→ 继续请求；否则标记需要登录并跳过
//

import Foundation

/// 登录态判定结果。
public enum LoginState: Sendable {
    /// 无需登录（loginUrl 为空）
    case notRequired
    /// 已登录（loginCheckJs 返回 true，或注入了 Cookie）
    case loggedIn
    /// 需要登录（loginCheckJs 返回 false 或无 Cookie），应跳过该源
    case requiresLogin
}

/// 登录态判断器。
enum LoginGate {

    /// 判断书源登录态。
    static func check(source: PaquBookSource, cookieStore: CookieStore) -> LoginState {
        guard let loginUrl = source.loginUrl, !loginUrl.isEmpty else {
            return .notRequired
        }

        let host = source.host ?? ""

        // 有 loginCheckJs → 执行它判断
        if let checkJs = source.loginCheckJs, !checkJs.isEmpty {
            let runtime = JSRuntime(cookieStore: cookieStore)
            runtime.setSourceHost(host)
            // 注入 loginUrl 供 js 使用
            let result = runtime.run(checkJs, key: "", page: 1, baseURL: source.bookSourceUrl)
            return isTrue(result) ? .loggedIn : .requiresLogin
        }

        // 无 loginCheckJs → 有无 Cookie 作为登录态依据
        if host.isEmpty { return .requiresLogin }
        return cookieStore.hasCookie(forHost: host) ? .loggedIn : .requiresLogin
    }

    /// 解析 loginCheckJs 的返回值：true/1/yes → 已登录。
    private static func isTrue(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return v == "true" || v == "1" || v == "yes" || v == "ok"
    }
}
