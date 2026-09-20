//
//  PaquBookSource.swift
//  BookSourceFetcher
//
//  Legado（阅读 App）书源格式的数据模型。
//

import Foundation

/// 一个 Legado 书源。
public struct PaquBookSource: Codable, Sendable, Identifiable {
    public var id: String { bookSourceName + "_" + (bookSourceUrl ?? "") }

    public let bookSourceName: String
    public let bookSourceGroup: String?
    public let bookSourceUrl: String?
    public let bookSourceType: Int?
    public let bookUrlPattern: String?
    public let customOrder: Int?
    public let enabled: Bool?
    public let enabledCookieJar: Bool?
    public let enabledExplore: Bool?
    public let exploreUrl: String?
    public let header: String?
    public let lastUpdateTime: Int?
    public let loginUrl: String?
    public let loginUi: String?
    public let loginCheckJs: String?
    public let coverDecodeJs: String?
    public let jsLib: String?
    public let concurrentRate: String?
    public let respondTime: Int?
    public let ruleBookInfo: BookInfoRule?
    public let ruleContent: ContentRule?
    public let ruleExplore: ExploreRule?
    public let ruleSearch: SearchRule?
    public let ruleToc: TocRule?
    public let searchUrl: String?
    public let weight: Int?
    /// 审计元数据（usable_sources.json 里的 `_audit`）：tier 能力分级 + 实测计数。
    /// 用于搜索时按 tier 降序优先调度快源/全通源；非内置源（如测试 mock）为 nil。
    public let audit: SourceAuditMeta?

    public init(
        bookSourceName: String,
        bookSourceGroup: String?,
        bookSourceUrl: String?,
        bookSourceType: Int?,
        bookUrlPattern: String?,
        customOrder: Int?,
        enabled: Bool?,
        enabledCookieJar: Bool?,
        enabledExplore: Bool?,
        exploreUrl: String?,
        header: String?,
        lastUpdateTime: Int?,
        loginUrl: String?,
        loginUi: String?,
        loginCheckJs: String?,
        coverDecodeJs: String?,
        jsLib: String?,
        concurrentRate: String?,
        respondTime: Int?,
        ruleBookInfo: BookInfoRule?,
        ruleContent: ContentRule?,
        ruleExplore: ExploreRule?,
        ruleSearch: SearchRule?,
        ruleToc: TocRule?,
        searchUrl: String?,
        weight: Int?,
        audit: SourceAuditMeta? = nil
    ) {
        self.bookSourceName = bookSourceName
        self.bookSourceGroup = bookSourceGroup
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceType = bookSourceType
        self.bookUrlPattern = bookUrlPattern
        self.customOrder = customOrder
        self.enabled = enabled
        self.enabledCookieJar = enabledCookieJar
        self.enabledExplore = enabledExplore
        self.exploreUrl = exploreUrl
        self.header = header
        self.lastUpdateTime = lastUpdateTime
        self.loginUrl = loginUrl
        self.loginUi = loginUi
        self.loginCheckJs = loginCheckJs
        self.coverDecodeJs = coverDecodeJs
        self.jsLib = jsLib
        self.concurrentRate = concurrentRate
        self.respondTime = respondTime
        self.ruleBookInfo = ruleBookInfo
        self.ruleContent = ruleContent
        self.ruleExplore = ruleExplore
        self.ruleSearch = ruleSearch
        self.ruleToc = ruleToc
        self.searchUrl = searchUrl
        self.weight = weight
        self.audit = audit
    }

    /// 是否启用（缺省视为启用）。
    public var isEnabled: Bool { enabled ?? true }

    /// 是否启用 CookieJar（缺省视为启用，对应 Legado 默认 true）。
    public var isCookieJarEnabled: Bool { enabledCookieJar ?? true }

    /// 书源 host（从 bookSourceUrl 提取，用于 cookie 定位）。
    public var host: String? {
        guard let url = bookSourceUrl, let u = URL(string: url), let h = u.host else { return nil }
        return h.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case bookSourceName, bookSourceGroup, bookSourceUrl, bookSourceType
        case bookUrlPattern, customOrder, enabled, enabledCookieJar, enabledExplore
        case exploreUrl, header, lastUpdateTime, loginUrl, loginUi, loginCheckJs
        case coverDecodeJs, jsLib, concurrentRate, respondTime
        case ruleBookInfo, ruleContent, ruleExplore, ruleSearch, ruleToc
        case searchUrl, weight
        case audit = "_audit"
    }
}

/// 书源的审计元数据（对应 usable_sources.json 的 `_audit` 字段）。
public struct SourceAuditMeta: Codable, Sendable {
    public let tier: Int?
    public let tierLabel: String?
    public let searchCount: Int?
    public let introLen: Int?
    public let tocCount: Int?

    enum CodingKeys: String, CodingKey {
        case tier
        case tierLabel = "tier_label"
        case searchCount
        case introLen
        case tocCount
    }

    /// 用于排序的 tier：无审计元数据视为 0（排在最后）。
    public var tierValue: Int { tier ?? 0 }
    public var searchCountValue: Int { searchCount ?? 0 }
}

/// 搜索规则（ruleSearch）。
public struct SearchRule: Codable, Sendable {
    public let author: String?
    public let bookList: String?
    public let bookUrl: String?
    public let checkKeyWord: String?
    public let coverUrl: String?
    public let intro: String?
    public let kind: String?
    public let lastChapter: String?
    public let name: String?
    public let wordCount: String?

    public init(
        author: String?, bookList: String?, bookUrl: String?, checkKeyWord: String?,
        coverUrl: String?, intro: String?, kind: String?, lastChapter: String?,
        name: String?, wordCount: String?
    ) {
        self.author = author; self.bookList = bookList; self.bookUrl = bookUrl
        self.checkKeyWord = checkKeyWord; self.coverUrl = coverUrl; self.intro = intro
        self.kind = kind; self.lastChapter = lastChapter; self.name = name
        self.wordCount = wordCount
    }
}

/// 书籍详情规则（ruleBookInfo）。
public struct BookInfoRule: Codable, Sendable {
    /// 初始化规则：先用此规则处理响应体，再提取各字段（如 `"$.data"` 表示取 JSON 根的 data 字段）。
    public let `init`: String?
    public let author: String?
    public let coverUrl: String?
    public let intro: String?
    public let kind: String?
    public let lastChapter: String?
    public let name: String?
    public let tocUrl: String?
    public let wordCount: String?
}

/// 目录规则（ruleToc）。
public struct TocRule: Codable, Sendable {
    /// 章节列表选择器。支持前缀：`-` 表示倒序，`+` 表示保持原序。
    public let chapterList: String?
    public let chapterName: String?
    public let chapterUrl: String?
    /// 翻页规则：返回下一页 URL。
    public let nextTocUrl: String?
    /// 章节名后处理 JS（提取后对 chapterName 做二次加工）。
    public let formatJs: String?
    public let updateTime: String?
}

/// 正文规则（ruleContent）。
public struct ContentRule: Codable, Sendable {
    public let content: String?
    public let nextContentUrl: String?
    public let webJs: String?
}

/// 发现页规则（ruleExplore）。
public struct ExploreRule: Codable, Sendable {
    public let bookList: String?
    public let name: String?
    public let author: String?
    public let bookUrl: String?
    public let coverUrl: String?
}

// MARK: - 详情页 & 目录 数据模型

/// 书籍详情页解析结果（由 ruleBookInfo 解析得出）。
public struct BookInfo: Codable, Sendable {
    public let name: String?
    public let author: String?
    public let coverUrl: String?
    public let intro: String?
    public let tocUrl: String?
    public let kind: String?
    public let wordCount: String?
    public let lastChapter: String?
}

/// 单个章节（由 ruleToc 解析得出）。
public struct Chapter: Codable, Sendable, Equatable {
    public let name: String
    public let url: String
    public let updateTime: String?
}

/// 搜索后继续执行详情与目录规则得到的完整书籍结果。
public struct ResolvedBook: Codable, Sendable, Equatable {
    public let title: String
    public var author: String?
    public let intro: String?
    public let coverUrl: String?
    public let provider: String
    public let bookUrl: String?
    public let chapters: [Chapter]
}
