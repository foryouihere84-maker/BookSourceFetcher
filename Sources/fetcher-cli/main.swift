import Foundation
import BookSourceFetcher
#if canImport(WebKit)
import WebKit
#endif

// 用法：
//   fetcher-cli "书名" [书源JSON路径或URL]                普通搜索
//   fetcher-cli --probe "书名" [书源JSON路径或URL]         逐个源统计命中数
//   fetcher-cli --cookie "host=cookie" "书名" [...]       注入登录 Cookie
//   fetcher-cli --webview "URL"                           用 WebView 渲染并返回 HTML（Layer 4）
//   fetcher-cli --info bookURL sourceName [书源JSON...]    获取书籍详情页
//   fetcher-cli --toc tocURL sourceName [书源JSON...]     获取书籍目录
//   fetcher-cli --openlib "书名"                          OpenLibrary 合规元数据搜索
let arguments = CommandLine.arguments

func defaultSourceURL() -> String {
    "https://cdn.mgz.la/shuyuan/250701%E6%9C%80%E5%90%8E%E4%B8%80%E7%89%88%E4%B8%80%E7%A8%8B.json"
}

/// 从可选的书源路径参数加载 PaquBookSourceFetcher（复用于 --info / --toc 命令）。
func loadFetcher(_ extraArgs: [String]) async throws -> PaquBookSourceFetcher {
    if let sourcePath = extraArgs.first {
        if sourcePath.hasPrefix("http://") || sourcePath.hasPrefix("https://") {
            return try await PaquBookSourceFetcher.load(sourceURL: URL(string: sourcePath)!)
        } else {
            let sources = try PaquBookSourceLoader.load(localFile: sourcePath)
            return PaquBookSourceFetcher(sources: sources)
        }
    } else {
        return try await PaquBookSourceFetcher.load(sourceURL: URL(string: defaultSourceURL())!)
    }
}

Task {
    do {
        var args = Array(arguments.dropFirst())

        // 解析 --cookie host=cookie 参数（可多次）
        var cookies: [(host: String, value: String)] = []
        while let idx = args.firstIndex(of: "--cookie"), args.count > idx + 1 {
            let pair = args[idx + 1]
            if let eq = pair.firstIndex(of: "=") {
                let host = String(pair[..<eq])
                let value = String(pair[pair.index(after: eq)...])
                cookies.append((host, value))
            }
            args.removeSubrange(idx...idx + 1)
        }

        // --webview URL 模式：测试 Layer 4 渲染
        if let idx = args.firstIndex(of: "--webview"), args.count > idx + 1 {
            let url = args[idx + 1]
            #if canImport(WebKit)
            let renderer = await MainActor.run { WebViewRenderer() }
            let html = await renderer.loadHTML(url: url)
            if let html {
                print(html.prefix(2000))
            } else {
                print("(WebView 渲染失败或无内容)")
            }
            #else
            print("当前平台不支持 WebKit")
            #endif
            exit(0)
        }

        // --crawler-probe 模式：复刻 App 内 BookSourceCrawler 的参数（8并发 + 6s单源 + 15s整体预算）
        // 可选第二个参数指定整体预算（秒），用于验证"部分结果"语义。
        if args.first == "--crawler-probe" {
            let rest = Array(args.dropFirst())
            let bookName = rest.count > 0 ? rest[0] : "万古江河"
            let budget = rest.count > 1 ? (TimeInterval(rest[1]) ?? 15) : 15
            let sources = try PaquBookSourceLoader.loadBundled()
            let fetcher = PaquBookSourceFetcher(
                sources: sources,
                maxConcurrentSources: 8,
                sourceTimeout: 6,
                maxResultsPerSource: 5
            )
            let start = Date()
            let response = await fetcher.fetch(bookName: bookName, overallTimeout: budget)
            let elapsed = Date().timeIntervalSince(start)
            print("复刻 BookSourceCrawler（8并发 + 6s单源 + \(budget)s整体预算）")
            print("实际等待: \(String(format: "%.2f", elapsed))s")
            print("爬虫返回结果数: \(response.data.results.count)")
            for r in response.data.results {
                print("  - \(r.title) | \(r.author ?? "无作者") | \(r.provider ?? "无源")")
            }
            exit(0)
        }

        // --stream-probe 模式：验证流式 fetchStream（每完成一个源 yield 一批，未跨源去重）
        if args.first == "--stream-probe" {
            let rest = Array(args.dropFirst())
            let bookName = rest.count > 0 ? rest[0] : "万古江河"
            let budget = rest.count > 1 ? (TimeInterval(rest[1]) ?? 15) : 15
            let sources = try PaquBookSourceLoader.loadBundled()
            let fetcher = PaquBookSourceFetcher(
                sources: sources,
                maxConcurrentSources: 8,
                sourceTimeout: 6,
                maxResultsPerSource: 5
            )
            let start = Date()
            var batchIndex = 0
            var totalItems = 0
            for await items in fetcher.fetchStream(bookName: bookName, overallTimeout: budget) {
                batchIndex += 1
                totalItems += items.count
                let elapsed = Date().timeIntervalSince(start)
                print("[批次\(batchIndex) @ \(String(format: "%.2f", elapsed))s] +\(items.count) 条（累计 \(totalItems) 条）")
                for it in items {
                    print("    - \(it.title) | \(it.author ?? "无作者") | \(it.provider ?? "无源")")
                }
            }
            let total = Date().timeIntervalSince(start)
            print("流式结束: 共 \(batchIndex) 批、\(totalItems) 条（未去重），总耗时 \(String(format: "%.2f", total))s")
            exit(0)
        }

        // --e2e 模式：搜索→详情→目录 全链路诊断
        if args.first == "--e2e" {
            let bookName = args.count > 1 ? args[1] : "斗破苍穹"
            let sourcePath = args.count > 2 ? args[2] : "shuyuan_filtered.json"
            let fetcher: PaquBookSourceFetcher
            if sourcePath.hasPrefix("http://") || sourcePath.hasPrefix("https://") {
                fetcher = try await PaquBookSourceFetcher.load(sourceURL: URL(string: sourcePath)!)
            } else {
                fetcher = PaquBookSourceFetcher(sources: try PaquBookSourceLoader.load(localFile: sourcePath))
            }
            print(await fetcher.diagnose(bookName: bookName))
            exit(0)
        }

        // --audit 模式：全量结构化审计（搜索→简介→目录），输出 JSON
        if args.first == "--audit" {
            let bookName = args.count > 1 ? args[1] : "斗破苍穹"
            let sourcePath = args.count > 2 ? args[2] : "shuyuan_filtered.json"
            let fetcher: PaquBookSourceFetcher
            if sourcePath.hasPrefix("http://") || sourcePath.hasPrefix("https://") {
                fetcher = try await PaquBookSourceFetcher.load(sourceURL: URL(string: sourcePath)!)
            } else {
                fetcher = PaquBookSourceFetcher(sources: try PaquBookSourceLoader.load(localFile: sourcePath))
            }
            let audits = await fetcher.audit(bookName: bookName)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(audits)
            if let json = String(data: data, encoding: .utf8) { print(json) }
            exit(0)
        }

        // --info bookURL sourceName 模式：获取书籍详情页
        if let idx = args.firstIndex(of: "--info"), args.count > idx + 2 {
            let bookURL = args[idx + 1]
            let sourceName = args[idx + 2]
            let extraArgs = Array(args.dropFirst(idx + 3))
            let fetcher = try await loadFetcher(extraArgs)
            if let info = await fetcher.fetchBookInfo(bookURL: bookURL, sourceName: sourceName) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(info)
                if let json = String(data: data, encoding: .utf8) { print(json) }
            } else {
                print("{\"error\": \"未找到书源或详情页解析失败\"}")
            }
            exit(0)
        }

        // --openlib "书名" 模式：OpenLibrary 合规元数据搜索
        if let idx = args.firstIndex(of: "--openlib"), args.count > idx + 1 {
            let bookName = args[idx + 1]
            let response = await OpenLibraryFetcher.search(query: bookName)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response)
            if let json = String(data: data, encoding: .utf8) { print(json) }
            exit(0)
        }

        // --toc tocURL sourceName 模式：获取书籍目录
        if let idx = args.firstIndex(of: "--toc"), args.count > idx + 2 {
            let tocURL = args[idx + 1]
            let sourceName = args[idx + 2]
            let extraArgs = Array(args.dropFirst(idx + 3))
            let fetcher = try await loadFetcher(extraArgs)
            let chapters = await fetcher.fetchToc(tocURL: tocURL, sourceName: sourceName)
            let wrapper: [String: Any] = ["chapters": chapters.map { ["name": $0.name, "url": $0.url, "updateTime": $0.updateTime ?? ""] }]
            if let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            } else {
                print("{\"chapters\": []}")
            }
            exit(0)
        }

        let probeMode = args.first == "--probe"
        if probeMode { args.removeFirst() }

        guard let bookName = args.first else {
            print("用法: fetcher-cli \"书籍名称\" [书源JSON路径或URL]")
            exit(1)
        }

        let fetcher: PaquBookSourceFetcher
        if args.count >= 2 {
            let sourcePath = args[1]
            if sourcePath.hasPrefix("http://") || sourcePath.hasPrefix("https://") {
                fetcher = try await PaquBookSourceFetcher.load(sourceURL: URL(string: sourcePath)!)
            } else {
                let sources = try PaquBookSourceLoader.load(localFile: sourcePath)
                fetcher = PaquBookSourceFetcher(sources: sources)
            }
        } else {
            fetcher = try PaquBookSourceFetcher.loadBundled()
        }

        // 注入 Cookie
        for c in cookies {
            fetcher.injectCookie(c.value, forHost: c.host)
        }

        if probeMode {
            let probes = await fetcher.probe(bookName: bookName)
            for p in probes.sorted(by: { $0.resultCount > $1.resultCount }) {
                let group = p.group ?? ""
                print("\(String(format: "%3d", p.resultCount)) 条 | \(group) | \(p.name)")
            }
            let usable = probes.filter { $0.resultCount > 0 }.count
            let total = probes.count
            print("---")
            print("可用源 \(usable) / 总计 \(total)")
            exit(0)
        }

        let response = await fetcher.fetch(bookName: bookName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(0)
    } catch {
        print("错误: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
