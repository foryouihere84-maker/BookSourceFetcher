import XCTest
import Foundation
@testable import BookSourceFetcher

final class BookSourceSDKTests: XCTestCase {
    func testConfigurationNormalizesInvalidValues() {
        let configuration = BookSourceSDKConfiguration(
            maxConcurrentSources: 0,
            sourceTimeout: 0,
            maxResultsPerSource: -1,
            maxSources: 0
        )

        XCTAssertEqual(configuration.maxConcurrentSources, 1)
        XCTAssertEqual(configuration.sourceTimeout, 0.1)
        XCTAssertEqual(configuration.maxResultsPerSource, 0)
        XCTAssertNil(configuration.maxSources)
    }

    func testSDKSearchFacade() async throws {
        let sourceJSON = """
        [{
          "bookSourceName": "SDK Mock",
          "bookSourceUrl": "https://sdk.example.com",
          "enabled": true,
          "searchUrl": "/search?q={{key}}",
          "ruleSearch": {
            "bookList": ".result",
            "name": ".title@text",
            "author": ".author@text",
            "bookUrl": ".title@href"
          }
        }]
        """
        let sources = try PaquBookSourceLoader.decode(Data(sourceJSON.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SDKMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let sdk = BookSourceSDK(sources: sources, session: session)

        let response = await sdk.search("测试书", timeout: 1)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.data.results.count, 1)
        XCTAssertEqual(response.data.results.first?.title, "测试书")
        XCTAssertEqual(response.data.results.first?.author, "作者甲")
        XCTAssertEqual(response.data.results.first?.provider, "SDK Mock")
    }

    func testBundledFactoryLoadsPackagedSources() throws {
        let sdk = try BookSourceSDK.bundled()
        XCTAssertNotNil(sdk)
        XCTAssertEqual(BookSourceSDK.version, "1.0.0")
    }
}

private final class SDKMockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let html = """
        <html><body><div class="result"><a class="title" href="/book/1">测试书</a><span class="author">作者甲</span></div></body></html>
        """
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
