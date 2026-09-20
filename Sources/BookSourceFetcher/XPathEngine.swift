//
//  XPathEngine.swift
//  BookSourceFetcher
//
//  轻量 XPath 求值器，支持 Legado 书源中常见的 XPath 模式。
//  不依赖第三方库，基于 SwiftSoup 解析的 DOM 结构实现。
//
//  支持的 XPath 模式：
//  - //div[@class='xxx']        CSS 等价选择
//  - //div[contains(@class,'x')]
//  - //a/@href                  属性提取
//  - //div/text()               文本提取
//  - //div[1]                   索引选择（1-based）
//  - 组合路径：//div[@class='x']//a
//

import Foundation
import SwiftSoup

enum XPathEngine {

    /// 执行 XPath 表达式，从给定 Element 中查找匹配的元素。
    static func evaluate(_ xpath: String, in element: Element) -> [Element] {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 转换为 CSS 选择器后用 SwiftSoup 执行
        if let css = xpathToCSS(trimmed) {
            do {
                let results = try element.select(css).array()
                return results
            } catch {
                return []
            }
        }
        return []
    }

    /// 执行 XPath 表达式并提取文本/属性值。
    static func evaluateText(_ xpath: String, in element: Element) -> String? {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)

        // 处理 /@attr 结尾（属性提取）
        if trimmed.hasSuffix(")") || trimmed.contains("/@") {
            let attrName = extractLastAttribute(from: trimmed)
            let elemXPath = attrName != nil ? String(trimmed.dropLast("/@\(attrName!)".count)) : trimmed

            if let css = xpathToCSS(elemXPath), let attrName {
                if let el = try? element.select(css).first() {
                    let val = (try? el.attr(attrName)) ?? ""
                    return val.isEmpty ? nil : val
                }
            }
        }

        // 处理 /text() 结尾（文本提取）
        if trimmed.hasSuffix("/text()") {
            let elemXPath = String(trimmed.dropLast("/text()".count))
            if let css = xpathToCSS(elemXPath) {
                if let el = try? element.select(css).first() {
                    let text = (try? el.text()) ?? ""
                    return text.isEmpty ? nil : text
                }
            }
        }

        // 默认：提取元素文本
        if let css = xpathToCSS(trimmed) {
            if let el = try? element.select(css).first() {
                let text = (try? el.text()) ?? ""
                return text.isEmpty ? nil : text
            }
        }

        return nil
    }

    // MARK: - XPath → CSS 转换

    /// 将 Legado 常见 XPath 转为 CSS 选择器。无法转换时返回 nil。
    private static func xpathToCSS(_ xpath: String) -> String? {
        var x = xpath
        // 去掉开头的 //
        if x.hasPrefix("//") {
            x = String(x.dropFirst(2))
        } else if x.hasPrefix("/") {
            x = String(x.dropFirst(1))
        }

        // 逐段处理
        let segments = x.components(separatedBy: "/")
        var cssParts: [String] = []

        for segment in segments {
            guard !segment.isEmpty else { continue }

            // 处理 [N] 索引（1-based → nth-child）
            if let bracketRange = segment.range(of: #"\[(\d+)\]"#, options: .regularExpression) {
                let match = String(segment[bracketRange])
                let numStr = match.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if let num = Int(numStr), num > 0 {
                    let tag = String(segment[..<bracketRange.lowerBound])
                    let tagName = extractTagName(tag)
                    if tagName.isEmpty {
                        cssParts.append("*:nth-child(\(num))")
                    } else {
                        cssParts.append("\(tagName):nth-child(\(num))")
                    }
                    continue
                }
            }

            // 处理 [@class='xxx'] 或 [contains(@class,'xxx')]
            if segment.contains("@class") {
                if let className = extractAttrValue(segment, attr: "class") {
                    let tag = extractTagBeforeBracket(segment)
                    let tagName = tag.isEmpty ? "*" : tag
                    cssParts.append("\(tagName).\(className)")
                    continue
                }
                if let className = extractContainsValue(segment, attr: "class") {
                    let tag = extractTagBeforeBracket(segment)
                    let tagName = tag.isEmpty ? "*" : tag
                    cssParts.append("\(tagName).\(className)")
                    continue
                }
            }

            // 处理 [@id='xxx']
            if segment.contains("@id") {
                if let idValue = extractAttrValue(segment, attr: "id") {
                    let tag = extractTagBeforeBracket(segment)
                    let tagName = tag.isEmpty ? "*" : tag
                    cssParts.append("\(tagName)#\(idValue)")
                    continue
                }
            }

            // 处理其他 [@attr='value'] — 转为 [attr='value']
            if segment.contains("[@") {
                if let attrName = extractBracketAttrName(segment),
                   let attrValue = extractAttrValue(segment, attr: attrName) {
                    let tag = extractTagBeforeBracket(segment)
                    let tagName = tag.isEmpty ? "*" : tag
                    cssParts.append("\(tagName)[\(attrName)='\(attrValue)']")
                    continue
                }
            }

            // 纯标签名（如 div, a, span）
            let tag = extractTagName(segment)
            if !tag.isEmpty {
                cssParts.append(tag)
            } else {
                cssParts.append("*")
            }
        }

        let result = cssParts.joined(separator: " > ")
        return result.isEmpty ? nil : result
    }

    // MARK: - 辅助方法

    /// 从 "a[@href]" 或 "a" 中提取标签名。
    private static func extractTagName(_ s: String) -> String {
        var tag = s
        // 去掉 [...] 部分
        if let bracketStart = tag.firstIndex(of: "[") {
            tag = String(tag[..<bracketStart])
        }
        tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        // 过滤掉非标签字符
        if tag.allSatisfy({ $0.isLetter || $0 == "*" }) {
            return tag
        }
        return ""
    }

    /// 从 "div[contains(@class,'xxx')]" 提取 contains 里的值。
    private static func extractContainsValue(_ s: String, attr: String) -> String? {
        let pattern = #"contains\(@\#(attr),\s*'([^']+)'\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
              let range = Range(match.range(at: 1), in: s) else {
            return nil
        }
        return String(s[range])
    }

    /// 从 "tag[@attr='value']" 提取 attr 值。
    private static func extractAttrValue(_ s: String, attr: String) -> String? {
        let pattern = #"@\#(attr)\s*=\s*'([^']+)'"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
              let range = Range(match.range(at: 1), in: s) else {
            return nil
        }
        return String(s[range])
    }

    /// 从 "[@attr='value']" 前面提取标签名。
    private static func extractTagBeforeBracket(_ s: String) -> String {
        if let idx = s.firstIndex(of: "[") {
            return String(s[..<idx])
        }
        return s
    }

    /// 从 "[@attr='...']" 提取属性名。
    private static func extractBracketAttrName(_ s: String) -> String? {
        guard let bracketStart = s.firstIndex(of: "[") else { return nil }
        let inner = String(s[s.index(after: bracketStart)...])
        if inner.hasPrefix("@") {
            let afterAt = String(inner.dropFirst(1))
            if let eqIdx = afterAt.firstIndex(of: "=") {
                return String(afterAt[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// 从 ".../@attr" 末尾提取属性名。
    private static func extractLastAttribute(from xpath: String) -> String? {
        guard let slashIdx = xpath.lastIndex(of: "/"), xpath.index(after: slashIdx) < xpath.endIndex else {
            return nil
        }
        let afterSlash = String(xpath[xpath.index(after: slashIdx)...])
        if afterSlash.hasPrefix("@") {
            return String(afterSlash.dropFirst(1))
        }
        return nil
    }
}
