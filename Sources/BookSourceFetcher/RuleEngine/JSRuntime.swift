//
//  JSRuntime.swift
//  BookSourceFetcher
//
//  增强的 JS 运行时：注入 java.* 工具函数（md5 / base64 / put / get），
//  维护跨请求变量存储，用于执行书源里的 @js / <js> 动态签名规则。
//

import Foundation
import JavaScriptCore
import CryptoKit

private typealias JSShouldTerminateCallback = @convention(c) (
    JSContextRef?, UnsafeMutableRawPointer?
) -> Bool

// Exported by JavaScriptCore on the package's supported Apple platforms, but
// omitted from the SDK's public Swift overlay.
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(
    _ group: JSContextGroupRef?,
    _ limit: Double,
    _ callback: JSShouldTerminateCallback?,
    _ context: UnsafeMutableRawPointer?
)

@_silgen_name("JSContextGroupClearExecutionTimeLimit")
private func JSContextGroupClearExecutionTimeLimit(_ group: JSContextGroupRef?)

private func terminateJavaScriptExecution(
    _ context: JSContextRef?,
    _ userData: UnsafeMutableRawPointer?
) -> Bool {
    true
}

/// JS 运行时：一个 JSContext + java.* 桥接 + 变量存储。
final class JSRuntime {
    static let defaultExecutionTimeout: TimeInterval = 3

    /// 共享的 JS 虚拟机（JSCore 隔离堆）。
    ///
    /// `JSContext()` 默认会为每个 context 单独创建一个 `JSVirtualMachine`，每个 VM 拥有
    /// 独立的内存堆与 GC。搜索链路会为每个书源、每个 `@js`/`<js>` 规则各 new 一个
    /// `JSRuntime`，一次搜索可能创建上百个独立 VM——Swift ARC 释放 context 后，VM 堆的
    /// 回收依赖 JSCore GC 触发，存在明显滞后，表现为「搜索后内存持续增长、迟迟不回落」。
    ///
    /// 改为共享同一个 VM：所有 context 复用同一隔离堆，GC 更高效、分配开销大幅下降，
    /// 同时每个 context 依旧相互隔离（线程安全），不改变任何执行语义。
    private static let sharedVM = JSVirtualMachine()!
    /// The execution limit belongs to the shared VM, so configuring and running
    /// a script must be one atomic operation across all contexts in that VM.
    private static let executionLock = NSRecursiveLock()

    private let context: JSContext
    private let executionTimeout: TimeInterval
    private(set) var storage: [String: String] = [:]
    /// 可选 Cookie 存储，供 java.getCookie/putCookie/removeCookie 桥接。
    private let cookieStore: CookieStore?
    /// 当前书源 host，供 cookie 桥接定位域名。
    private var sourceHost: String = ""

    init(
        cookieStore: CookieStore? = nil,
        executionTimeout: TimeInterval = JSRuntime.defaultExecutionTimeout
    ) {
        self.cookieStore = cookieStore
        self.executionTimeout = max(0.01, executionTimeout)
        self.context = JSContext(virtualMachine: Self.sharedVM)!
        installJavaBridge()
    }

    // MARK: - java.* 桥接

    private func installJavaBridge() {
        guard let java = JSValue(newObjectIn: context) else { return }

        // java.md5Encode(str) -> 32 位小写 MD5
        let md5: @convention(block) (String) -> String = { input in
            let digest = Insecure.MD5.hash(data: input.data(using: .utf8) ?? Data())
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(md5, forKeyedSubscript: "md5Encode" as NSString)

        // java.base64Encode(str) -> Base64
        let base64: @convention(block) (String) -> String = { input in
            Data(input.utf8).base64EncodedString()
        }
        java.setObject(base64, forKeyedSubscript: "base64Encode" as NSString)

        // java.put(key, value) -> 存变量，返回空串
        let put: @convention(block) (String, String) -> String = { [weak self] key, value in
            self?.storage[key] = value
            return ""
        }
        java.setObject(put, forKeyedSubscript: "put" as NSString)

        // java.get(key) -> 取变量
        let get: @convention(block) (String) -> String = { [weak self] key in
            self?.storage[key] ?? ""
        }
        java.setObject(get, forKeyedSubscript: "get" as NSString)

        // java.getCookie([host]) -> 当前书源的 Cookie 字符串（可选参数，无参时用 sourceHost）
        let getCookie: @convention(block) (String?) -> String = { [weak self] hostArg in
            guard let self else { return "" }
            let arg = hostArg ?? ""
            // JavaScriptCore 无参调用会传入 "undefined" 字符串，需一并视作缺省
            let host = (arg.isEmpty || arg == "undefined" || arg == "null") ? self.sourceHost : arg
            guard !host.isEmpty else { return "" }
            return self.cookieStore?.cookie(forHost: host) ?? ""
        }
        java.setObject(getCookie, forKeyedSubscript: "getCookie" as NSString)

        // java.putCookie(key, value) -> 写入单个 cookie，返回空串
        let putCookie: @convention(block) (String, String) -> String = { [weak self] key, value in
            guard let self, !self.sourceHost.isEmpty else { return "" }
            self.cookieStore?.merge(cookieString: "\(key)=\(value)", forHost: self.sourceHost)
            return ""
        }
        java.setObject(putCookie, forKeyedSubscript: "putCookie" as NSString)

        // java.removeCookie(key) -> 删除单个 cookie
        let removeCookie: @convention(block) (String) -> String = { [weak self] key in
            guard let self, !self.sourceHost.isEmpty else { return "" }
            if let current = self.cookieStore?.cookie(forHost: self.sourceHost) {
                var map = CookieStore.cookieToMap(current)
                map.removeValue(forKey: key)
                self.cookieStore?.remove(forHost: self.sourceHost)
                if !map.isEmpty {
                    let merged = map.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: "; ")
                    self.cookieStore?.merge(cookieString: merged, forHost: self.sourceHost)
                }
            }
            return ""
        }
        java.setObject(removeCookie, forKeyedSubscript: "removeCookie" as NSString)

        context.setObject(java, forKeyedSubscript: "java" as NSString)
    }

    /// 设置当前书源 host（用于 cookie 桥接定位）。
    func setSourceHost(_ host: String) {
        sourceHost = host.lowercased()
    }

    /// 写入变量存储（供外部注入 bookUrl 等上下文变量）。
    func put(_ key: String, _ value: String) {
        storage[key] = value
    }

    /// 在 JSContext 上设置一个 Block 函数（供 CoverDecryptor 注入 getByteArray 等）。
    func setObject(_ object: Any, forKeyedSubscript key: String) {
        context.setObject(object, forKeyedSubscript: key as NSString)
    }

    /// 直接在 JSContext 中声明一个全局变量（绕过字符串字面量编码问题）。
    func setVariable(_ name: String, value: String) {
        context.setObject(value, forKeyedSubscript: name as NSString)
    }

    // MARK: - 执行

    /// 执行 JS，返回字符串结果（undefined / null 返回 nil）。
    @discardableResult
    func run(_ script: String, key: String, page: Int, baseURL: String?) -> String? {
        withExecutionLimit {
            context.setObject(key, forKeyedSubscript: "key" as NSString)
            context.setObject(page, forKeyedSubscript: "page" as NSString)
            context.setObject(baseURL ?? "", forKeyedSubscript: "baseUrl" as NSString)
            let value = context.evaluateScript(script)
            guard let str = value?.toString(), str != "undefined", str != "null" else {
                return nil
            }
            return str
        }
    }

    /// 解析 JS 对象 / JSON 字面量（支持单引号、无引号 key），返回字典。
    /// 例如 "{'method':'POST','body':'x=1'}" -> ["method": "POST", "body": "x=1"]
    func parseObject(_ literal: String) -> [String: Any]? {
        let trimmed = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return withExecutionLimit {
            guard let jsonStr = context.evaluateScript("JSON.stringify(\(trimmed))")?.toString(),
                  let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }
    }

    private func withExecutionLimit<T>(_ body: () -> T?) -> T? {
        Self.executionLock.lock()
        defer { Self.executionLock.unlock() }

        let group = JSContextGetGroup(context.jsGlobalContextRef)
        JSContextGroupSetExecutionTimeLimit(
            group,
            executionTimeout,
            terminateJavaScriptExecution,
            nil
        )
        defer { JSContextGroupClearExecutionTimeLimit(group) }

        context.exception = nil
        return body()
    }
}

/// 静态 JS 执行器（供 RuleEngine 的 @js 规则使用）。
/// 优先复用 context 携带的 runtime（同一搜索任务内共享 JSContext，避免新建），
/// 为 nil 时退化为新建（详情/测试路径，保持原行为）。
enum JSRunner {
    static func run(_ js: String, context: RuleContext, runtime: JSRuntime? = nil) -> String? {
        let r = runtime ?? context.runtime ?? JSRuntime()
        return r.run(js, key: context.key, page: context.page, baseURL: context.baseURL?.absoluteString)
    }
}
