import XCTest
import Foundation
@testable import BookSourceFetcher

final class BookSourceFetcherTests: XCTestCase {

    func testTitleNormalizer() {
        XCTAssertEqual(BookTitleNormalizer.normalize("有理想就有疼痛"), "有理想就有疼痛")
        XCTAssertEqual(BookTitleNormalizer.normalize("有理想就有疼痛（全一册）"), "有理想就有疼痛")
        XCTAssertEqual(BookTitleNormalizer.normalize("  ABC  "), "abc")
    }

    func testJSONPathEvaluate() {
        let json: [String: Any] = [
            "data": [
                ["id": "1", "name": "书A", "author_name": "作者A"],
                ["id": "2", "name": "书B", "author_name": "作者B"]
            ]
        ]
        let value = JSONPath.evaluate("$.data[*]", root: json)
        XCTAssertNotNil(value)
        XCTAssertEqual(JSONPath.asArray(value).count, 2)

        let first = JSONPath.evaluate("$.data[0].name", root: json)
        XCTAssertEqual(JSONPath.stringify(first), "书A")
    }

    func testSearchRequestBuilderGet() {
        let source = PaquBookSource(
            bookSourceName: "test", bookSourceGroup: nil, bookSourceUrl: "https://example.com",
            bookSourceType: 0, bookUrlPattern: nil, customOrder: nil, enabled: true,
            enabledCookieJar: nil, enabledExplore: nil, exploreUrl: nil, header: nil,
            lastUpdateTime: nil, loginUrl: nil, loginUi: nil, loginCheckJs: nil,
            coverDecodeJs: nil, jsLib: nil, concurrentRate: nil, respondTime: nil,
            ruleBookInfo: nil, ruleContent: nil, ruleExplore: nil, ruleSearch: nil,
            ruleToc: nil, searchUrl: "/search?keyword={{key}}&page={{page}}", weight: nil
        )
        let spec = SearchRequestBuilder.build(from: source, key: "测试", page: 1, runtime: JSRuntime())
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.urlString, "https://example.com/search?keyword=%E6%B5%8B%E8%AF%95&page=1")
        XCTAssertEqual(spec?.method, "GET")
    }

    func testSearchRequestBuilderMultilineConfigAndCookieDirective() {
        let source = PaquBookSource(
            bookSourceName: "test", bookSourceGroup: nil, bookSourceUrl: "https://example.com/catalog/index.html",
            bookSourceType: 0, bookUrlPattern: nil, customOrder: nil, enabled: true,
            enabledCookieJar: nil, enabledExplore: nil, exploreUrl: nil, header: nil,
            lastUpdateTime: nil, loginUrl: nil, loginUi: nil, loginCheckJs: nil,
            coverDecodeJs: nil, jsLib: nil, concurrentRate: nil, respondTime: nil,
            ruleBookInfo: nil, ruleContent: nil, ruleExplore: nil, ruleSearch: nil,
            ruleToc: nil,
            searchUrl: "{{cookie.removeCookie(source.getKey())}}\nsearch?q={{key}}\n,{'method':'POST','body':'keyword={{key}}','headers':{'X-Test':'ok'}}",
            weight: nil
        )
        let spec = SearchRequestBuilder.build(from: source, key: "斗破苍穹", page: 1, runtime: JSRuntime())
        XCTAssertEqual(spec?.urlString, "https://example.com/catalog/search?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9")
        XCTAssertEqual(spec?.method, "POST")
        XCTAssertEqual(spec?.body, "keyword=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9")
        XCTAssertEqual(spec?.headers["X-Test"], "ok")
    }

    func testJSMD5Signature() {
        // 验证 java.md5Encode 桥接可用
        let runtime = JSRuntime()
        let result = runtime.run("java.md5Encode('hello')", key: "", page: 1, baseURL: nil)
        XCTAssertEqual(result, "5d41402abc4b2a76b9719d911017c592")
    }

    func testJSObjectParse() {
        // 验证单引号对象字面量解析
        let runtime = JSRuntime()
        let obj = runtime.parseObject("{'method':'POST','body':'x=1'}")
        XCTAssertEqual(obj?["method"] as? String, "POST")
        XCTAssertEqual(obj?["body"] as? String, "x=1")
    }

    func testJSExecutionTimeoutInterruptsInfiniteLoopAndRuntimeRecovers() {
        let runtime = JSRuntime(executionTimeout: 0.05)
        let startedAt = Date()

        XCTAssertNil(runtime.run("while (true) {}", key: "", page: 1, baseURL: nil))
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
        XCTAssertEqual(runtime.run("1 + 1", key: "", page: 1, baseURL: nil), "2")
    }

    // MARK: - Layer 3 登录态 / Cookie

    func testCookieStoreInjectAndRead() {
        let store = CookieStore()
        store.inject(cookieString: "token=abc123; uid=42", forHost: "api-bc.wtzw.com")

        // 精确 host 匹配
        XCTAssertEqual(store.cookie(forHost: "api-bc.wtzw.com"), "token=abc123; uid=42")

        // 父域回退
        let url = URL(string: "https://api-bc.wtzw.com/search")!
        XCTAssertEqual(store.cookie(for: url), "token=abc123; uid=42")

        // 无 cookie 的域名返回 nil
        XCTAssertNil(store.cookie(forHost: "other.com"))
    }

    func testCookieStoreMerge() {
        let store = CookieStore()
        store.inject(cookieString: "a=1; b=2", forHost: "x.com")
        store.inject(cookieString: "b=3; c=4", forHost: "x.com") // b 覆盖，c 新增
        let cookie = store.cookie(forHost: "x.com") ?? ""
        let map = CookieStore.cookieToMap(cookie)
        XCTAssertEqual(map["a"], "1")
        XCTAssertEqual(map["b"], "3")
        XCTAssertEqual(map["c"], "4")
    }

    func testCookieMergeStatic() {
        let merged = CookieStore.mergeCookies("a=1", "b=2; a=9")
        let map = CookieStore.cookieToMap(merged ?? "")
        XCTAssertEqual(map["a"], "9")
        XCTAssertEqual(map["b"], "2")
    }

    func testLoginGateNoLoginUrl() {
        let source = PaquBookSource(
            bookSourceName: "s", bookSourceGroup: nil, bookSourceUrl: "https://x.com",
            bookSourceType: 0, bookUrlPattern: nil, customOrder: nil, enabled: true,
            enabledCookieJar: nil, enabledExplore: nil, exploreUrl: nil, header: nil,
            lastUpdateTime: nil, loginUrl: nil, loginUi: nil, loginCheckJs: nil,
            coverDecodeJs: nil, jsLib: nil, concurrentRate: nil, respondTime: nil,
            ruleBookInfo: nil, ruleContent: nil, ruleExplore: nil, ruleSearch: nil,
            ruleToc: nil, searchUrl: "/s?q={{key}}", weight: nil
        )
        XCTAssertEqual(LoginGate.check(source: source, cookieStore: CookieStore()), .notRequired)
    }

    func testLoginGateCheckJs() {
        let store = CookieStore()
        store.inject(cookieString: "token=ok", forHost: "x.com")

        // loginCheckJs 返回 true → 已登录
        let source = PaquBookSource(
            bookSourceName: "s", bookSourceGroup: nil, bookSourceUrl: "https://x.com",
            bookSourceType: 0, bookUrlPattern: nil, customOrder: nil, enabled: true,
            enabledCookieJar: nil, enabledExplore: nil, exploreUrl: nil, header: nil,
            lastUpdateTime: nil, loginUrl: "https://x.com/login", loginUi: nil,
            loginCheckJs: "java.getCookie().indexOf('token')>=0 ? 'true':'false'",
            coverDecodeJs: nil, jsLib: nil, concurrentRate: nil, respondTime: nil,
            ruleBookInfo: nil, ruleContent: nil, ruleExplore: nil, ruleSearch: nil,
            ruleToc: nil, searchUrl: "/s?q={{key}}", weight: nil
        )
        XCTAssertEqual(LoginGate.check(source: source, cookieStore: store), .loggedIn)

        // 无 cookie → 未登录
        XCTAssertEqual(LoginGate.check(source: source, cookieStore: CookieStore()), .requiresLogin)
    }

    func testLoginGateCookieAsFallback() {
        // 无 loginCheckJs：有 cookie 视为已登录
        let source = PaquBookSource(
            bookSourceName: "s", bookSourceGroup: nil, bookSourceUrl: "https://x.com",
            bookSourceType: 0, bookUrlPattern: nil, customOrder: nil, enabled: true,
            enabledCookieJar: nil, enabledExplore: nil, exploreUrl: nil, header: nil,
            lastUpdateTime: nil, loginUrl: "https://x.com/login", loginUi: nil, loginCheckJs: nil,
            coverDecodeJs: nil, jsLib: nil, concurrentRate: nil, respondTime: nil,
            ruleBookInfo: nil, ruleContent: nil, ruleExplore: nil, ruleSearch: nil,
            ruleToc: nil, searchUrl: "/s?q={{key}}", weight: nil
        )
        let store = CookieStore()
        XCTAssertEqual(LoginGate.check(source: source, cookieStore: store), .requiresLogin)
        store.inject(cookieString: "session=1", forHost: "x.com")
        XCTAssertEqual(LoginGate.check(source: source, cookieStore: store), .loggedIn)
    }

    func testJSCookieBridge() {
        let store = CookieStore()
        store.inject(cookieString: "token=abc", forHost: "x.com")
        let runtime = JSRuntime(cookieStore: store)
        runtime.setSourceHost("x.com")

        // java.getCookie 返回注入的 cookie
        XCTAssertEqual(runtime.run("java.getCookie()", key: "", page: 1, baseURL: nil), "token=abc")

        // java.putCookie 写入后 java.getCookie 可读到
        _ = runtime.run("java.putCookie('uid','7')", key: "", page: 1, baseURL: nil)
        XCTAssertEqual(runtime.run("java.getCookie()", key: "", page: 1, baseURL: nil), "token=abc; uid=7")
    }

    // MARK: - Layer 4 webView 标记

    func testSearchRequestBuilderWebViewFlag() {
        let source = PaquBookSource(
            bookSourceName: "当阅读网", bookSourceGroup: nil, bookSourceUrl: "https://www.dangyuedu.com",
            bookSourceType: 0, bookUrlPattern: nil, customOrder: nil, enabled: true,
            enabledCookieJar: nil, enabledExplore: nil, exploreUrl: nil, header: nil,
            lastUpdateTime: nil, loginUrl: nil, loginUi: nil, loginCheckJs: nil,
            coverDecodeJs: nil, jsLib: nil, concurrentRate: nil, respondTime: nil,
            ruleBookInfo: nil, ruleContent: nil, ruleExplore: nil, ruleSearch: nil,
            ruleToc: nil,
            searchUrl: "{{cookie.removeCookie(source.getKey())}}\nhttps://www.sososhu.com/?q={{key}}&site=dangyuedu&Submit=,{'webView': true}",
            weight: nil
        )
        let spec = SearchRequestBuilder.build(from: source, key: "斗破苍穹", page: 1, runtime: JSRuntime())
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.webView, true)
        XCTAssertEqual(spec?.urlString, "https://www.sososhu.com/?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9&site=dangyuedu&Submit=")
    }

    func testJSONPathRecursiveAndArrayProjection() {
        let json: [String: Any] = [
            "outer": ["name": "根"],
            "data": [
                ["name": "书A"],
                ["name": "书B"]
            ]
        ]
        let recursiveNames = JSONPath.stringify(JSONPath.evaluate("$..name", root: json))?.split(separator: ",").map(String.init) ?? []
        XCTAssertEqual(Set(recursiveNames), Set(["根", "书A", "书B"]))
        XCTAssertEqual(JSONPath.stringify(JSONPath.evaluate("$.data[*].name", root: json)), "书A,书B")
    }

    func testResolveSearchInfoAndTocWithMockSession() async {
        MockURLProtocol.responses = [
            "https://example.com/catalog/search?q=%E6%B5%8B%E8%AF%95": """
            <html><body><div class="result"><a class="title" href="../books/demo/index.html">测试之书</a><span class="author">作者甲</span></div></body></html>
            """,
            "https://example.com/books/demo/index.html": """
            <html><body><h1 class="name">测试之书</h1><span class="author">作者甲</span><p class="intro">这是一本测试简介。</p><img class="cover" src="cover.jpg"><a class="toc" href="chapters/page-1.html">目录</a></body></html>
            """,
            "https://example.com/books/demo/chapters/page-1.html": """
            <html><body><ul class="chapters"><li><a href="../chapter-1.html">第一章</a></li><li><a href="../chapter-2.html">第二章</a></li></ul></body></html>
            """
        ]
        let source = PaquBookSource(
            bookSourceName: "Mock", bookSourceGroup: nil, bookSourceUrl: "https://example.com/catalog/index.html",
            bookSourceType: 0, bookUrlPattern: nil, customOrder: nil, enabled: true,
            enabledCookieJar: nil, enabledExplore: nil, exploreUrl: nil, header: nil,
            lastUpdateTime: nil, loginUrl: nil, loginUi: nil, loginCheckJs: nil,
            coverDecodeJs: nil, jsLib: nil, concurrentRate: nil, respondTime: nil,
            ruleBookInfo: BookInfoRule(init: nil, author: ".author@text", coverUrl: ".cover@src", intro: ".intro@text", kind: nil, lastChapter: nil, name: ".name@text", tocUrl: ".toc@href", wordCount: nil),
            ruleContent: nil, ruleExplore: nil,
            ruleSearch: SearchRule(author: ".author@text", bookList: ".result", bookUrl: "a.title@href", checkKeyWord: nil, coverUrl: nil, intro: nil, kind: nil, lastChapter: nil, name: "a.title@text", wordCount: nil),
            ruleToc: TocRule(chapterList: ".chapters li", chapterName: "a@text", chapterUrl: "a@href", nextTocUrl: nil, formatJs: nil, updateTime: nil),
            searchUrl: "search?q={{key}}", weight: nil
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let fetcher = PaquBookSourceFetcher(sources: [source], session: URLSession(configuration: config), maxConcurrentSources: 1)
        let books = await fetcher.resolve(bookName: "测试", maxResults: 1)

        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books[0].title, "测试之书")
        XCTAssertEqual(books[0].intro, "这是一本测试简介。")
        XCTAssertEqual(books[0].coverUrl, "https://example.com/books/demo/cover.jpg")
        XCTAssertEqual(books[0].chapters, [
            Chapter(name: "第一章", url: "https://example.com/books/demo/chapter-1.html", updateTime: nil),
            Chapter(name: "第二章", url: "https://example.com/books/demo/chapter-2.html", updateTime: nil)
        ])
    }

    // MARK: - JS runtime 复用（内存驻留修复回归）

    func testJSRuntimeReuseAcrossRuleEvaluations() {
        // 验证：同一 runtime 复用求值多条 @js 规则，结果正确、java.* 桥接可用、无状态残留。
        let runtime = JSRuntime()
        let ctx = RuleContext(key: "测试", page: 1, baseURL: nil, runtime: runtime)

        // @js: 前缀规则（JSRunner 复用 context.runtime）
        XCTAssertEqual(RuleEngine.evaluate("@js:'a' + 'b'", in: ctx), "ab")
        XCTAssertEqual(RuleEngine.evaluate("@js:6 * 7", in: ctx), "42")
        // 复用后 java.* 桥接仍可用
        XCTAssertEqual(RuleEngine.evaluate("@js:java.md5Encode('hello')", in: ctx), "5d41402abc4b2a76b9719d911017c592")

        // 关键断言：@js 规则复用了传入的 runtime（而非新建）——java.put 写入在外部可见。
        _ = RuleEngine.evaluate("@js:java.put('k','v')", in: ctx)
        XCTAssertEqual(runtime.storage["k"], "v")
    }

    func testJSRuntimeReuseNilContextFallsBackToNew() {
        // 无 runtime 的 context（详情/测试路径）退化为新建，结果仍正确。
        let ctx = RuleContext(key: "测试", page: 1, baseURL: nil, runtime: nil)
        XCTAssertEqual(RuleEngine.evaluate("@js:2 + 3", in: ctx), "5")
    }
}

private final class MockURLProtocol: URLProtocol {
    static var responses: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let body = Self.responses[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
