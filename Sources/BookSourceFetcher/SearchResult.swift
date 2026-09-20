//
//  SearchResult.swift
//  BookSourceFetcher
//
//  对齐用户要求的返回格式。
//

import Foundation

/// 顶层返回结构：{ "success": true, "data": { "results": [...] } }
public struct BookFetchResponse: Codable, Sendable {
    public let success: Bool
    public let data: BookFetchData

    public init(success: Bool, results: [BookFetchItem]) {
        self.success = success
        self.data = BookFetchData(results: results)
    }
}

public struct BookFetchData: Codable, Sendable {
    public let results: [BookFetchItem]

    public init(results: [BookFetchItem]) {
        self.results = results
    }
}

/// 单条书籍结果。字段与用户示例一致：
/// title / author / intro / isbn / publisher / cover_url / provider
public struct BookFetchItem: Codable, Sendable, Equatable {
    public let title: String
    public let author: String?
    public let intro: String?
    public let isbn: String?
    public let publisher: String?
    public let coverUrl: String?
    public let provider: String?

    public init(title: String, author: String?, intro: String?, isbn: String?, publisher: String?, coverUrl: String?, provider: String?) {
        self.title = title
        self.author = author
        self.intro = intro
        self.isbn = isbn
        self.publisher = publisher
        self.coverUrl = coverUrl
        self.provider = provider
    }

    enum CodingKeys: String, CodingKey {
        case title, author, intro, isbn, publisher
        case coverUrl = "cover_url"
        case provider
    }

    /// 用于去重/判等的键：书名（归一化后）+ 作者。
    var dedupeKey: String {
        let t = BookTitleNormalizer.normalize(title)
        let a = (author ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(t)|\(a)"
    }
}

/// 搜索结果（从书源解析出的原始条目，尚未组装成 BookFetchItem）。
struct ParsedBookItem: Sendable {
    let title: String?
    let author: String?
    let coverUrl: String?
    let bookUrl: String?
    let intro: String?
    let provider: String

    var isValid: Bool {
        !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
