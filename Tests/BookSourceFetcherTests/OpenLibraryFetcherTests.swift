import XCTest
import Foundation
@testable import BookSourceFetcher

final class OpenLibraryFetcherTests: XCTestCase {

    func testBuildSearchURL() {
        let url = OpenLibraryFetcher.buildSearchURL(query: "武极天下", limit: 20)
        XCTAssertEqual(url?.host, "openlibrary.org")
        XCTAssertEqual(url?.path, "/search.json")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "武极天下")
        XCTAssertEqual(items.first(where: { $0.name == "limit" })?.value, "20")
    }

    func testParseSearchResponse() {
        let json = """
        {
          "numFound": 2,
          "docs": [
            {
              "title": "武极天下",
              "author_name": ["蚕茧里的牛"],
              "first_publish_year": 2014,
              "language": ["chi"],
              "cover_i": 1234567,
              "key": "/works/OL1234567W"
            },
            {
              "title": "The Three-Body Problem",
              "author_name": ["Liu Cixin", "Ken Liu"],
              "first_publish_year": 2006,
              "language": ["eng"],
              "cover_i": null,
              "key": "/works/OL1111111W"
            }
          ]
        }
        """
        let books = OpenLibraryFetcher.parse(data: Data(json.utf8))
        XCTAssertEqual(books.count, 2)

        let first = books[0]
        XCTAssertEqual(first.title, "武极天下")
        XCTAssertEqual(first.author, "蚕茧里的牛")
        XCTAssertEqual(first.year, "2014")
        XCTAssertEqual(first.language, "Chinese")
        XCTAssertEqual(first.coverUrl, "https://covers.openlibrary.org/b/id/1234567-L.jpg")
        XCTAssertEqual(first.bookUrl, "https://openlibrary.org/works/OL1234567W")
        XCTAssertNil(first.fileFormat)
        XCTAssertNil(first.fileSize)
        XCTAssertNil(first.rating)

        let second = books[1]
        XCTAssertEqual(second.title, "The Three-Body Problem")
        XCTAssertEqual(second.author, "Liu Cixin") // 多作者取第一个
        XCTAssertEqual(second.language, "English")
        XCTAssertNil(second.coverUrl) // cover_i 为 null
    }

    func testParseMissingFieldsDoesNotCrash() {
        let json = """
        {
          "numFound": 2,
          "docs": [
            { "title": "仅书名" },
            {}
          ]
        }
        """
        let books = OpenLibraryFetcher.parse(data: Data(json.utf8))
        XCTAssertEqual(books.count, 1) // 空 doc 无 title 被丢弃
        XCTAssertEqual(books[0].title, "仅书名")
        XCTAssertNil(books[0].author)
        XCTAssertNil(books[0].coverUrl)
        XCTAssertNil(books[0].bookUrl)
        XCTAssertNil(books[0].language)
        XCTAssertNil(books[0].year)
    }

    func testParseInvalidJSONReturnsEmpty() {
        XCTAssertTrue(OpenLibraryFetcher.parse(data: Data("not json".utf8)).isEmpty)
    }
}
