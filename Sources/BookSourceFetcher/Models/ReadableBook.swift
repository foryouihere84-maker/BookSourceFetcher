import Foundation

/// Network metadata only; reading progress belongs to the host application.
public struct ReadableBook: Codable, Sendable, Equatable {
    public var type: Int = 0
    public var updateTime: String? = nil
    public var downloadUrls: [String]? = nil
    public var bookUrl: String
    public var tocUrl: String
    public var sourceUrl: String
    public var sourceName: String
    public var name: String
    public var author: String?
    public var intro: String?
    public var coverUrl: String?
    public var kind: String?
    public var wordCount: String?
    public var latestChapterTitle: String?
    public var variables: [String: String]
    public var chapters: [ReadableChapter]

    public init(bookUrl: String, sourceUrl: String, sourceName: String = "", name: String = "",
                tocUrl: String? = nil, author: String? = nil, intro: String? = nil,
                coverUrl: String? = nil, kind: String? = nil, wordCount: String? = nil,
                latestChapterTitle: String? = nil, variables: [String: String] = [:],
                chapters: [ReadableChapter] = []) {
        self.bookUrl = bookUrl; self.tocUrl = tocUrl ?? bookUrl
        self.sourceUrl = sourceUrl; self.sourceName = sourceName; self.name = name
        self.author = author; self.intro = intro; self.coverUrl = coverUrl
        self.kind = kind; self.wordCount = wordCount; self.latestChapterTitle = latestChapterTitle
        self.variables = variables; self.chapters = chapters
    }
}

public struct ReadableChapter: Codable, Sendable, Equatable {
    public var baseUrl: String? = nil
    public var wordCount: String? = nil
    public var index: Int
    public var title: String
    public var url: String
    public var bookUrl: String
    public var isVolume: Bool
    public var isVip: Bool
    public var isPay: Bool
    public var tag: String?
    public var variables: [String: String]

    public init(index: Int, title: String, url: String, bookUrl: String,
                isVolume: Bool = false, isVip: Bool = false, isPay: Bool = false,
                tag: String? = nil, variables: [String: String] = [:]) {
        self.index = index; self.title = title; self.url = url; self.bookUrl = bookUrl
        self.isVolume = isVolume; self.isVip = isVip; self.isPay = isPay
        self.tag = tag; self.variables = variables
    }
}

public struct ChapterContent: Codable, Sendable, Equatable {
    public let chapter: ReadableChapter
    /// Normalized text, with absolute <img src="…"> markers preserved.
    public let content: String
    public let pageURLs: [String]
    public let imageStyle: String?
}

public struct BookReadAttempt: Codable, Sendable, Equatable {
    public let sourceUrl: String
    public let bookUrl: String?
    public let message: String
}

/// `complete` means all requested chapters succeeded, not that the whole book was downloaded.
public struct BookReadResponse: Codable, Sendable {
    public let book: ReadableBook?
    public let contents: [ChapterContent]
    public let requestedChapters: Int
    public let complete: Bool
    public let attempts: [BookReadAttempt]
    public let success: Bool

    init(book: ReadableBook?, contents: [ChapterContent], requestedChapters: Int,
         complete: Bool, attempts: [BookReadAttempt]) {
        self.book = book; self.contents = contents; self.requestedChapters = requestedChapters
        self.complete = complete; self.attempts = attempts; self.success = !contents.isEmpty
    }
}

public enum BookReadingError: Error, LocalizedError, Sendable {
    case sourceNotFound(String)
    case invalidURL(String)
    case http(Int, String)
    case missingRule(String)
    case empty(String)
    case unsupported(String)
    case pageLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let value): return "未找到书源：\(value)"
        case .invalidURL(let value): return "无效 URL：\(value)"
        case .http(let code, let url): return "HTTP \(code)：\(url)"
        case .missingRule(let field): return "缺少规则：\(field)"
        case .empty(let stage): return "\(stage)为空"
        case .unsupported(let feature): return "当前不支持：\(feature)"
        case .pageLimit(let count): return "分页超过上限 \(count)，结果未完成"
        }
    }
}
