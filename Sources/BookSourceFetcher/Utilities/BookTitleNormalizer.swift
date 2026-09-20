//
//  BookTitleNormalizer.swift
//  BookSourceFetcher
//
//  书名字符串归一化，用于搜索结果去重。
//

import Foundation

enum BookTitleNormalizer {

    /// 归一化书名：去空白、去括号副标题、全角转半角、小写。
    static func normalize(_ title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns = [
            "\\s*[\\(（].*?[\\)）]",
            "\\s*【.*?】",
            "\\s*《.*?》",
            "\\s*：.*$",
            "\\s*:.*$"
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: "",
                options: .regularExpression
            )
        }

        result = result.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? result
        result = result.replacingOccurrences(
            of: "\\s+", with: "",
            options: .regularExpression
        )
        return result.lowercased()
    }
}
