import Foundation
import XCTest
import SwiftSoup
@testable import BookSourceFetcher

final class BookReadingTests: XCTestCase {
    private func source(_ host: String = "books.test", extra: [String: Any] = [:]) throws -> PaquBookSource {
        var json: [String: Any] = [
            "bookSourceName": host, "bookSourceUrl": "https://\(host)",
            "searchUrl": "/search?q={{key}}", "enabled": true,
            "ruleSearch": ["bookList": ".book", "name": "a@text", "author": ".author@text",
                           "bookUrl": "a@href@js:java.put('token','search-token'); result", "kind": ".kind@text", "wordCount": ".words@text"],
            "ruleBookInfo": ["name": "h1@text", "intro": "#intro@html", "tocUrl": "#toc@href"],
            "ruleToc": ["chapterList": ".toc@a", "chapterName": "text", "chapterUrl": "href",
                        "nextTocUrl": ".next@href", "isVolume": "@data-volume", "isVip": "@data-vip", "updateTime": "@data-time"],
            "ruleContent": ["content": "#content@html", "title": "h1@text", "nextContentUrl": ".next@href", "replaceRegex": "##AD_START[\\s\\S]*?AD_END##"]
        ]
        json.merge(extra) { _, new in new }
        return try JSONDecoder().decode(PaquBookSource.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func sdk(_ sources: [PaquBookSource]) -> BookSourceSDK {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReadingProtocol.self]
        return BookSourceSDK(sources: sources, session: URLSession(configuration: config))
    }

    func testEndToEndSearchDetailPaginatedTocAndContent() async throws {
        let client = sdk([try source()])
        let response = try await client.read("测试书", author: "作者甲", chapterLimit: 2, minimumContentLength: 1)
        XCTAssertTrue(response.success)
        XCTAssertTrue(response.complete)
        let book = try XCTUnwrap(response.book)
        XCTAssertEqual(book.name, "测试书")
        XCTAssertEqual(book.kind, "历史")
        XCTAssertEqual(book.wordCount, "1000字")
        XCTAssertEqual(book.variables["token"], "search-token")
        XCTAssertEqual(book.chapters.count, 3) // volume + two chapters; repeated chapter deduped
        XCTAssertTrue(book.chapters[0].isVolume)
        XCTAssertEqual(book.chapters.map(\.index), [0, 1, 2])
        XCTAssertTrue(book.chapters[2].isVip)
        XCTAssertEqual(book.chapters[1].tag, "2026-09-20")
        XCTAssertEqual(response.contents.count, 2)
        XCTAssertEqual(response.contents[0].pageURLs.count, 2)
        XCTAssertEqual(response.contents[0].chapter.title, "第一章完整版")
        XCTAssertTrue(response.contents[0].content.contains("首段\n第二段"))
        XCTAssertTrue(response.contents[0].content.contains("尾段"))
        XCTAssertTrue(response.contents[0].content.contains("<img src=\"https://books.test/images/a.jpg\">"))
        XCTAssertFalse(response.contents[0].content.contains("AD_"))
        XCTAssertFalse(response.contents[0].content.contains("第二章独立正文"))
        XCTAssertEqual(response.contents[1].content, "第二章独立正文")
        let restored = try JSONDecoder().decode(ReadableBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(restored, book)
    }

    func testSearchRetainsSourceURLAndBookURL() async throws {
        let response = await sdk([try source()]).search("测试书")
        let item = try XCTUnwrap(response.data.results.first)
        XCTAssertEqual(item.bookUrl, "https://books.test/book/1")
        XCTAssertEqual(item.sourceUrl, "https://books.test")
        XCTAssertEqual(item.variables?["token"], "search-token")
    }

    func testFallbackRequiresActualTextNotOnlyMetadata() async throws {
        let bad = try source("broken.test", extra: ["_audit": ["tier": 4]])
        let result = try await sdk([bad, try source()]).read("测试书", chapterLimit: 1, minimumContentLength: 1)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.book?.sourceUrl, "https://books.test")
        XCTAssertTrue(result.attempts.contains { $0.sourceUrl == "https://broken.test" && $0.message.contains("503") })
    }

    func testPartialBookReportsFailureAndNeverMixesSources() async throws {
        let result = try await sdk([try source("partial.test")]).read("测试书", chapterLimit: 2, minimumContentLength: 1)
        XCTAssertTrue(result.success)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.requestedChapters, 2)
        XCTAssertEqual(result.contents.count, 1)
        XCTAssertTrue(result.attempts.contains { $0.message.contains("403") })
        XCTAssertEqual(result.contents[0].chapter.bookUrl, result.book?.bookUrl)
    }

    func testContentPageLimitDoesNotReturnTruncatedSuccess() async throws {
        let client = sdk([try source()])
        let book = try await client.openBook(bookURL: "https://books.test/book/1", sourceURL: "https://books.test")
        do {
            _ = try await client.content(book: book, chapter: book.chapters[1], maxPages: 1)
            XCTFail("Expected a page limit error")
        } catch BookReadingError.pageLimit(let limit) { XCTAssertEqual(limit, 1) }
    }

    func testJSONWithPostOptionsAndVariables() async throws {
        let rules: [String: Any] = [
            "ruleBookInfo": ["init": "$.data", "name": "$.name", "tocUrl": "$.toc@js:java.put('key','detail-key'); result"],
            "ruleToc": ["chapterList": "$.chapters", "chapterName": "$.title", "chapterUrl": "$.url"],
            "ruleContent": ["content": "$.text@js:java.get('key') + ':' + result", "nextContentUrl": "$.pages"]
        ]
        let client = sdk([try source("json.test", extra: rules)])
        let book = try await client.openBook(bookURL: "https://json.test/book/1", sourceURL: "https://json.test")
        let result = try await client.content(book: book, chapter: book.chapters[0])
        XCTAssertEqual(result.content, "detail-key:JSON 正文\ndetail-key:JSON 分页")
        XCTAssertEqual(result.pageURLs.count, 2)
    }

    func testDuplicateSourceNamesAreResolvedByURL() async throws {
        let a = try source("broken.test", extra: ["bookSourceName": "同名源"])
        let b = try source("books.test", extra: ["bookSourceName": "同名源"])
        let book = try await sdk([a, b]).openBook(bookURL: "https://books.test/book/1", sourceURL: "https://books.test")
        XCTAssertEqual(book.sourceUrl, "https://books.test")
    }

    func testCancelledReadPropagatesCancellation() async throws {
        let client = sdk([try source()])
        let task = Task { try await client.read("测试书") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testRuleCompositionAndInlineJS() throws {
        let doc = try SwiftSoup.parse("<div class='a'>甲</div><div class='b'>乙</div><ul><li>一</li><li>二</li></ul>")
        let runtime = JSRuntime()
        let ctx = RuleContext(element: doc, runtime: runtime)
        XCTAssertEqual(RuleEngine.evaluate(".a@text&&.b@text", in: ctx), "甲\n乙")
        XCTAssertEqual(RuleEngine.evaluate(".a@text@js:result + (true && true ? '丙' : '')", in: ctx), "甲丙")
        XCTAssertEqual(RuleEngine.evaluateElements("ul@li", in: ctx).count, 2)
        XCTAssertEqual(RuleEngine.evaluate("@CSS:li@text", in: ctx), "一\n二")
    }

    func testJSONTemplateInsideJavaScriptAndJavaGetString() {
        let runtime = JSRuntime()
        let ctx = RuleContext(json: ["seq": 12, "free": true], runtime: runtime)
        XCTAssertEqual(RuleEngine.evaluate("<js>'https://example.com?cid={{$.seq}}'</js>", in: ctx), "https://example.com?cid=12")
        XCTAssertEqual(RuleEngine.evaluate("{{java.getString('$.free') == 'true' ? 'false' : 'true'}}", in: ctx), "false")
        XCTAssertEqual(RuleEngine.evaluate("@put:{bid:'$.seq'}@get:{bid}", in: ctx), "12")
        XCTAssertEqual(runtime.storage["bid"], "12")
        XCTAssertEqual(RuleEngine.evaluate("{{$.seq##2##3}}", in: ctx), "13")
    }

    func testShortPlaceholderIsNotReportedAsReadableBook() async throws {
        let result = try await sdk([try source()]).read("测试书")
        XCTAssertFalse(result.success)
        XCTAssertFalse(result.complete)
        XCTAssertTrue(result.attempts.contains { $0.message.contains("最小长度") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(json["success"] as? Bool, false)
    }

    func testConcurrentRuntimeLifetimesDoNotCorruptSharedVM() async {
        await withTaskGroup(of: String?.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let runtime = JSRuntime()
                    return runtime.run("String(\(index))", key: "", page: 1, baseURL: nil)
                }
            }
            var results = Set<String>()
            for await result in group { if let result { results.insert(result) } }
            XCTAssertEqual(results.count, 100)
        }
    }
}

private final class ReadingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host!
        var status = 200
        let body: String
        if host == "json.test" {
            switch url.path {
            case "/book/1": body = #"{"data":{"name":"JSON书","toc":"/toc"}}"#
            case "/toc": body = #"{"chapters":[{"title":"第一章","url":"/post,{\"method\":\"POST\",\"body\":\"token=1\",\"headers\":{\"X-Test\":\"yes\"}}"}]}"#
            case "/post":
                if request.httpMethod != "POST" || request.value(forHTTPHeaderField: "X-Test") != "yes" { status = 400 }
                body = #"{"text":"JSON 正文","pages":["/page2"]}"#
            case "/page2": body = #"{"text":"JSON 分页","pages":["/post,{\"method\":\"POST\",\"body\":\"token=1\",\"headers\":{\"X-Test\":\"yes\"}}"]}"#
            default: status = 404; body = ""
            }
        } else {
            switch url.path {
            case "/search": body = "<div class='book'><a href='/book/1'>测试书</a><span class='author'>作者甲</span><span class='kind'>历史</span><span class='words'>1000字</span></div>"
            case "/book/1": body = "<h1>测试书</h1><div id='intro'>简介</div><a id='toc' href='/toc/1'>目录</a>"
            case "/toc/1": body = "<div class='toc'><a data-volume='true'>第一卷</a><a href='../chapter/1' data-time='2026-09-20'>第一章</a></div><a class='next' href='2'>下一页</a>"
            case "/toc/2": body = "<div class='toc'><a href='../chapter/1'>第一章重复</a><a href='../chapter/2' data-vip='true'>第二章</a></div><a class='next' href='1'>循环</a>"
            case "/chapter/1":
                if host == "broken.test" { status = 503 }
                body = "<h1>第一章完整版</h1><div id='content'><p>首段</p><p>第二段</p><img data-src='../images/a.jpg'>AD_START广告</div><a class='next' href='1-2'>下页</a>"
            case "/chapter/1-2": body = "<div id='content'>广告AD_END<p>尾段</p></div><a class='next' href='2'>下一章</a>"
            case "/chapter/2":
                if host == "partial.test" { status = 403 }
                body = "<div id='content'>第二章独立正文</div>"
            default: status = 404; body = ""
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
