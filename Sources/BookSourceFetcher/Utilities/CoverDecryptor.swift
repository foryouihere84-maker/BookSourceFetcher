//
//  CoverDecryptor.swift
//  BookSourceFetcher
//
//  执行书源的 coverDecodeJs 脚本，对封面进行解密/转换。
//  支持两种模式：
//  1. URL 解密：JS 脚本返回解密后的 URL 字符串
//  2. 字节解密：JS 脚本通过 java.put("imageBytes", ...) 存储解密后的图片字节
//

import Foundation

enum CoverDecryptor {

    /// 用 coverDecodeJs 解密封面 URL。
    /// - Parameters:
    ///   - coverURL: 原始封面 URL（从搜索结果或详情页提取）。
    ///   - js: coverDecodeJs 脚本内容。
    ///   - source: 所属书源（提供 bookSourceUrl 等上下文）。
    ///   - cookieStore: 可选 Cookie 存储（供 JS 内 java.getCookie 桥接）。
    ///   - bookURL: 书籍详情页 URL（部分脚本需要引用）。
    /// - Returns: 解密后的封面 URL，失败时返回原始 URL。
    static func decrypt(
        _ coverURL: String,
        js: String,
        source: PaquBookSource,
        cookieStore: CookieStore? = nil,
        bookURL: String? = nil
    ) -> String {
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return coverURL
        }

        let runtime = JSRuntime(cookieStore: cookieStore)
        runtime.setSourceHost(source.host ?? "")

        // 注入 Legado 标准变量（coverDecodeJs 里可引用）
        if let bookURL {
            runtime.put("bookUrl", bookURL)
        }

        // 执行脚本，封面 URL 通过 result 返回
        // Legado 的 coverDecodeJs 惯例：脚本最后一行返回解密后的 URL
        // 有些源通过 java.put("coverUrl", ...) 存储结果
        let result = runtime.run(js, key: coverURL, page: 1, baseURL: source.bookSourceUrl)

        // 优先取脚本返回值，其次取 java.put 存的 coverUrl
        if let returned = result, !returned.isEmpty, returned != "undefined", returned != "null" {
            return returned
        }
        if let stored = runtime.storage["coverUrl"], !stored.isEmpty {
            return stored
        }

        // 解密失败，返回原始 URL
        return coverURL
    }

    /// 下载封面图片并用 coverDecodeJs 解密字节数据。
    /// Legado 某些书源的 coverDecodeJs 不只是改 URL，而是对下载后的图片字节做解密
    /// （如 Base64 解码、AES 解密等），通过 java.put("imageBytes", base64Str) 返回。
    /// - Parameters:
    ///   - coverURL: 封面 URL。
    ///   - js: coverDecodeJs 脚本。
    ///   - source: 书源。
    ///   - session: URLSession。
    ///   - cookieStore: Cookie 存储。
    ///   - bookURL: 书籍详情页 URL。
    /// - Returns: 解密后的图片 Data，如果无需解密或失败返回 nil（调用方应直接用 URL 加载）。
    static func decryptImageBytes(
        _ coverURL: String,
        js: String,
        source: PaquBookSource,
        session: URLSession,
        cookieStore: CookieStore? = nil,
        bookURL: String? = nil
    ) async -> Data? {
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // 先执行 JS，看是否有 imageBytes 输出
        let runtime = JSRuntime(cookieStore: cookieStore)
        runtime.setSourceHost(source.host ?? "")
        if let bookURL { runtime.put("bookUrl", bookURL) }
        runtime.put("coverUrl", coverURL)

        // 注入图片下载函数供 JS 调用：java.getByteArray(url) 下载图片并返回 Base64
        let getByteArray: @convention(block) (String) -> String = { url in
            // 同步下载（在 JS 线程中，用信号量）
            let semaphore = DispatchSemaphore(value: 0)
            var base64Result = ""
            let task = URLSession.shared.dataTask(with: URL(string: url) ?? URL(string: "about:blank")!) { data, _, _ in
                if let data {
                    base64Result = data.base64EncodedString()
                }
                semaphore.signal()
            }
            task.resume()
            semaphore.wait()
            return base64Result
        }
        runtime.setObject(getByteArray, forKeyedSubscript: "getByteArray")

        _ = runtime.run(js, key: coverURL, page: 1, baseURL: source.bookSourceUrl)

        // 检查是否有解密后的图片字节
        if let imageBytesBase64 = runtime.storage["imageBytes"], !imageBytesBase64.isEmpty {
            return Data(base64Encoded: imageBytesBase64)
        }

        return nil
    }
}
