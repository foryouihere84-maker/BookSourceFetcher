//
//  PaquBookSourceLoader.swift
//  BookSourceFetcher
//
//  从远程 URL 下载书源 JSON，或从本地文件加载。
//

import Foundation

public enum PaquBookSourceLoader {

    /// 从 URL 加载书源列表（下载 + 解析）。
    public static func load(from url: URL, session: URLSession = .shared) async throws -> [PaquBookSource] {
        let (data, _) = try await session.data(from: url)
        return try decode(data)
    }

    /// 从本地文件加载书源列表。
    public static func load(localFile path: String) throws -> [PaquBookSource] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decode(data)
    }

    /// 从 Swift Package 内置资源加载书源（打包进 App 的精选可用源，无需联网）。
    /// 资源文件随 target 以 `.copy` 方式打包，文件名保留。
    public static func loadBundled(fileName: String = "usable_sources") throws -> [PaquBookSource] {
        guard let url = Bundle.module.url(forResource: fileName, withExtension: "json") else {
            throw NSError(
                domain: "PaquBookSourceLoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未找到内置书源文件 \(fileName).json"]
            )
        }
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    /// 解析书源 JSON（顶层为数组）。
    public static func decode(_ data: Data) throws -> [PaquBookSource] {
        let decoder = JSONDecoder()
        let sources = try decoder.decode([PaquBookSource].self, from: data)
        return sources
    }

    /// 过滤出启用的书源。
    public static func enabledSources(_ sources: [PaquBookSource]) -> [PaquBookSource] {
        sources.filter { $0.isEnabled && !($0.searchUrl ?? "").isEmpty }
    }
}
