//
//  WebViewRenderer.swift
//  BookSourceFetcher
//
//  Layer 4：webView + webJs（真实浏览器渲染）。
//  对应 Legado 的 webView / ContentRule.webJs 语义：
//    - 用 WKWebView 加载页面，等待 JS 渲染完成；
//    - 取渲染后的 HTML（document.documentElement.outerHTML）；
//    - 或执行一段 webJs 拿到结果（用于正文页/强反爬站点的 JS 渲染内容）。
//
//  注意：WKWebView 依赖主线程 RunLoop（macOS 需 NSApplication、iOS 需 UIApplication）。
//  在 App 环境可直接使用；纯 CLI 环境下需自建 RunLoop 驱动（见 README）。
//

import Foundation
#if canImport(WebKit)
import WebKit

/// WebView 渲染器。主线程（MainActor）使用。
@MainActor
public final class WebViewRenderer: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private var pendingJS: String?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var renderDelay: TimeInterval = 1.5
    private var waitForSelector: String?

    public override init() {
        super.init()
    }

    /// 加载 URL，等待 JS 渲染后返回渲染后的 HTML。
    /// - Parameters:
    ///   - waitForSelector: 等待某个 CSS 选择器元素出现后再取 HTML（SPA 异步渲染用）。
    public func loadHTML(
        url: String,
        timeout: TimeInterval = 20,
        renderDelay: TimeInterval = 1.5,
        waitForSelector: String? = nil
    ) async -> String? {
        await run(url: url, js: "document.documentElement.outerHTML",
                  timeout: timeout, renderDelay: renderDelay, waitForSelector: waitForSelector)
    }

    /// 加载 URL 后执行一段 webJs，返回其结果（正文页 webJs / 强反爬渲染）。
    public func runWebJs(
        url: String,
        js: String,
        timeout: TimeInterval = 20,
        renderDelay: TimeInterval = 1.5,
        waitForSelector: String? = nil
    ) async -> String? {
        await run(url: url, js: js,
                  timeout: timeout, renderDelay: renderDelay, waitForSelector: waitForSelector)
    }

    // MARK: - 内部

    private func run(
        url: String,
        js: String,
        timeout: TimeInterval,
        renderDelay: TimeInterval,
        waitForSelector: String?
    ) async -> String? {
        guard let target = URL(string: url) else { return nil }
        self.renderDelay = renderDelay
        self.waitForSelector = waitForSelector

        return await withCheckedContinuation { cont in
            continuation = cont
            pendingJS = js

            let config = WKWebViewConfiguration()
            // 允许不安全内容与本地存储，模拟真实浏览器
            config.websiteDataStore = .nonPersistent()
            let wv = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 800), configuration: config)
            wv.navigationDelegate = self
            webView = wv

            // 超时兜底
            let item = DispatchWorkItem { [weak self] in
                self?.finish(nil)
            }
            timeoutWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)

            wv.load(URLRequest(url: target))
        }
    }

    private func finish(_ result: String?) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        webView?.navigationDelegate = nil
        webView = nil
        pendingJS = nil
        waitForSelector = nil
        cont.resume(returning: result)
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let selector = waitForSelector, !selector.isEmpty {
            // 轮询等待 SPA 异步渲染出目标元素
            pollForSelector(selector, in: webView, deadline: Date().addingTimeInterval(10))
        } else {
            // 固定延迟后取 HTML
            let delay = renderDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.webView === webView else { return }
                self.evaluateAndFinish(in: webView)
            }
        }
    }

    /// 轮询等待选择器元素出现（最多 10 秒）。
    private func pollForSelector(_ selector: String, in webView: WKWebView, deadline: Date) {
        guard self.webView === webView else { return }
        if Date() > deadline {
            // 超时也取当前 HTML（可能已渲染）
            evaluateAndFinish(in: webView)
            return
        }
        let checkJS = "document.querySelector(\(selectorQuoted)) !== null"
        webView.evaluateJavaScript(checkJS) { [weak self] result, _ in
            guard let self, self.webView === webView else { return }
            if (result as? Bool) == true {
                self.evaluateAndFinish(in: webView)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.pollForSelector(selector, in: webView, deadline: deadline)
                }
            }
        }
    }

    private var selectorQuoted: String {
        // 把选择器安全地放进 JS 字符串
        let escaped = (waitForSelector ?? "").replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private func evaluateAndFinish(in webView: WKWebView) {
        let js = pendingJS ?? "document.documentElement.outerHTML"
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            let str: String?
            if let s = result as? String {
                str = s
            } else if let result, let data = try? JSONSerialization.data(withJSONObject: result),
                      let s = String(data: data, encoding: .utf8) {
                str = s
            } else {
                str = result.map { "\($0)" }
            }
            self.finish(str)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }
}
#endif
