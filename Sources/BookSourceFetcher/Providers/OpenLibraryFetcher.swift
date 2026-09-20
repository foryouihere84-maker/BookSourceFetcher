//
//  OpenLibraryFetcher.swift
//  BookSourceFetcher
//
//  合规的书籍元数据搜索源（OpenLibrary / Internet Archive）。
//
//  API: https://openlibrary.org/search.json?q={书名}&fields=...&limit=20
//  字段映射：
//    title   -> docs[].title
//    author  -> docs[].author_name[0]
//    cover   -> https://covers.openlibrary.org/b/id/{cover_i}-L.jpg
//    bookUrl -> https://openlibrary.org{key}（/works/OLxxxW）
//    language-> docs[].language[0]（ISO 码映射为可读英文名）
//    year    -> docs[].first_publish_year
//  file_format / file_size / rating：OpenLibrary 搜索接口不提供，恒为 nil。
//

import Foundation

/// OpenLibrary 单条书籍结构化信息。
public struct OpenLibraryBook: Codable, Sendable, Equatable {
    public let title: String
    public let author: String?
    /// 书籍详情页地址（https://openlibrary.org/works/OLxxxW）。
    public let coverUrl: String?
    public let bookUrl: String?
    public let language: String?
    public let year: String?
    /// OpenLibrary 搜索接口不提供，恒为 nil。
    public let fileFormat: String?
    /// OpenLibrary 搜索接口不提供，恒为 nil。
    public let fileSize: String?
    /// OpenLibrary 搜索接口不提供，恒为 nil。
    public let rating: String?

    public init(
        title: String,
        author: String?,
        coverUrl: String?,
        bookUrl: String?,
        language: String?,
        year: String?,
        fileFormat: String?,
        fileSize: String?,
        rating: String?
    ) {
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.bookUrl = bookUrl
        self.language = language
        self.year = year
        self.fileFormat = fileFormat
        self.fileSize = fileSize
        self.rating = rating
    }

    enum CodingKeys: String, CodingKey {
        case title, author, language, year, rating
        case coverUrl = "cover_url"
        case bookUrl = "book_url"
        case fileFormat = "file_format"
        case fileSize = "file_size"
    }
}

/// OpenLibrary 搜索响应：{ success, query, source, count, results }。
public struct OpenLibrarySearchResponse: Codable, Sendable {
    public let success: Bool
    public let query: String
    public let source: String
    public let count: Int
    public let results: [OpenLibraryBook]

    public init(success: Bool, query: String, source: String, results: [OpenLibraryBook]) {
        self.success = success
        self.query = query
        self.source = source
        self.count = results.count
        self.results = results
    }
}

/// OpenLibrary 合规元数据搜索源。
/// 用法：
///
///     let response = await OpenLibraryFetcher.search(query: "武极天下")
///     // response.results: [OpenLibraryBook]
public enum OpenLibraryFetcher {

    public static let defaultHost = "openlibrary.org"

    /// 单次搜索返回的最大条目数。
    public static var maxResults = 20

    /// 发起搜索：GET https://openlibrary.org/search.json?q={书名}
    /// - Parameters:
    ///   - query: 要搜索的书名。
    ///   - session: 可复用 URLSession，缺省为 ephemeral。
    public static func search(
        query: String,
        session: URLSession? = nil
    ) async -> OpenLibrarySearchResponse {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return OpenLibrarySearchResponse(success: false, query: key, source: defaultHost, results: [])
        }
        // OpenLibrary 硬限制：q 至少 3 个字符（"三体"这类 2 字书名会返回 422）。
        // 短查询直接返回空结果，避免浪费一次注定失败的请求。App 层可提示用户补作者名搜索。
        guard key.count >= 3 else {
            return OpenLibrarySearchResponse(success: false, query: key, source: defaultHost, results: [])
        }
        guard let url = buildSearchURL(query: key) else {
            return OpenLibrarySearchResponse(success: false, query: key, source: defaultHost, results: [])
        }

        let s = session ?? Self.makeSession()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await s.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return OpenLibrarySearchResponse(success: false, query: key, source: defaultHost, results: [])
        }

        let books = parse(data: data)
        return OpenLibrarySearchResponse(success: !books.isEmpty, query: key, source: defaultHost, results: books)
    }

    /// 构建搜索 URL：https://openlibrary.org/search.json?q={query}&fields=...&limit=N
    static func buildSearchURL(query: String, limit: Int = 20) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = defaultHost
        components.path = "/search.json"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "title,author_name,first_publish_year,language,cover_i,key"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        return components.url
    }

    /// 解析 OpenLibrary search.json 响应，映射为 OpenLibraryBook 数组。
    public static func parse(data: Data) -> [OpenLibraryBook] {
        guard let result = try? JSONDecoder().decode(OpenLibrarySearchResult.self, from: data) else {
            return []
        }
        return result.docs.compactMap(mapDoc)
    }

    /// 单条 doc 映射为 OpenLibraryBook（title 为空则丢弃）。
    private static func mapDoc(_ doc: OpenLibraryDoc) -> OpenLibraryBook? {
        guard let title = doc.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }

        let author = doc.authorName?.first?.trimmingCharacters(in: .whitespacesAndNewlines)

        var coverUrl: String?
        if let coverID = doc.coverI {
            coverUrl = "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg"
        }

        var bookUrl: String?
        if let key = doc.key, !key.isEmpty {
            bookUrl = "https://openlibrary.org\(key)"
        }

        var language: String?
        if let code = doc.language?.first {
            language = Self.languageName(for: code)
        }

        var year: String?
        if let y = doc.firstPublishYear {
            year = "\(y)"
        }

        return OpenLibraryBook(
            title: title,
            author: (author?.isEmpty == false) ? author : nil,
            coverUrl: coverUrl,
            bookUrl: bookUrl,
            language: language,
            year: year,
            fileFormat: nil,
            fileSize: nil,
            rating: nil
        )
    }

    /// ISO 639 语言码 → 可读英文名。
    /// 未知码原样返回。
    private static func languageName(for code: String) -> String {
        switch code.lowercased() {
        case "chi", "zho", "cmn": return "Chinese"
        case "eng": return "English"
        case "jpn": return "Japanese"
        case "kor": return "Korean"
        case "rus": return "Russian"
        case "fre", "fra": return "French"
        case "ger", "deu": return "German"
        case "spa": return "Spanish"
        case "por": return "Portuguese"
        case "ita": return "Italian"
        case "ara": return "Arabic"
        case "hin": return "Hindi"
        case "ind": return "Indonesian"
        case "tha": return "Thai"
        case "vie": return "Vietnamese"
        case "tur": return "Turkish"
        case "pol": return "Polish"
        case "ukr": return "Ukrainian"
        case "nld", "dut": return "Dutch"
        case "swe": return "Swedish"
        case "nor": return "Norwegian"
        case "dan": return "Danish"
        case "fin": return "Finnish"
        case "ces", "cze": return "Czech"
        case "hun": return "Hungarian"
        case "ron", "rum": return "Romanian"
        case "ell", "gre": return "Greek"
        case "heb": return "Hebrew"
        case "fas", "per": return "Persian"
        case "lat": return "Latin"
        default: return code
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }
}

// MARK: - OpenLibrary API 解码模型

private struct OpenLibrarySearchResult: Decodable {
    let numFound: Int
    let docs: [OpenLibraryDoc]
}

private struct OpenLibraryDoc: Decodable {
    let title: String?
    let authorName: [String]?
    let firstPublishYear: Int?
    let language: [String]?
    let coverI: Int?
    let key: String?

    enum CodingKeys: String, CodingKey {
        case title, language, key
        case authorName = "author_name"
        case firstPublishYear = "first_publish_year"
        case coverI = "cover_i"
    }
}
