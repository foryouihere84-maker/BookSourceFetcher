//
//  JSONPath.swift
//  BookSourceFetcher
//
//  Legado 书源用到的 JSONPath 子集实现。
//  支持：$.a.b.c、$.a[*]、$.a[0]、$..name、{{$.id}} 内插取值。
//

import Foundation

/// JSONPath 求值器。输入为 JSON 反序列化后的 Any。
enum JSONPath {

    /// 求值一个 JSONPath，返回匹配到的值（可能为 nil、标量、数组）。
    /// - Parameter path: 例如 "$.data"、"$.data[*]"、"$.result.books"、"$..className"
    /// - Parameter root: JSON 根对象
    static func evaluate(_ path: String, root: Any) -> Any? {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.hasPrefix("$") else { return nil }
        p.removeFirst()

        // 处理 || 或：$.data.novel_list||$.data
        let alternatives = p.components(separatedBy: "||")
        for alt in alternatives {
            let value = evaluateSingle(alt, root: root)
            if let value, !isEmpty(value) {
                return value
            }
        }
        return nil
    }

    private static func evaluateSingle(_ path: String, root: Any) -> Any? {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)

        // 递归下降 $..
        if p.hasPrefix("..") {
            p.removeFirst(2)
            let tokens = tokenize(p)
            let results = recursiveSearch(root, forTokens: tokens)
            return results.isEmpty ? nil : (results.count == 1 ? results[0] : results)
        }

        // 普通路径的根分隔点不参与字段名。
        if p.hasPrefix(".") { p.removeFirst() }

        var current: Any = root
        let tokens = tokenize(p)

        for token in tokens {
            current = step(current, token: token)
            if isEmpty(current) {
                return nil
            }
        }
        return current
    }

    /// 将路径切分为 token（支持 a.b.c、[0]、[*]）。
    private static func tokenize(_ path: String) -> [String] {
        var tokens: [String] = []
        var buffer = ""
        var i = path.startIndex

        func flushBuffer() {
            if !buffer.isEmpty {
                tokens.append(buffer)
                buffer = ""
            }
        }

        while i < path.endIndex {
            let c = path[i]
            if c == "." {
                flushBuffer()
            } else if c == "[" {
                flushBuffer()
                // 找到匹配的 ]
                var j = path.index(after: i)
                var inside = ""
                while j < path.endIndex && path[j] != "]" {
                    inside.append(path[j])
                    j = path.index(after: j)
                }
                tokens.append("[\(inside)]")
                i = j
            } else {
                buffer.append(c)
            }
            i = path.index(after: i)
        }
        flushBuffer()
        return tokens
    }

    private static func step(_ current: Any, token: String) -> Any {
        // 数组索引 / 通配
        if token.hasPrefix("[") && token.hasSuffix("]") {
            let inside = String(token.dropFirst().dropLast())
            guard let array = current as? [Any] else { return NSNull() }
            if inside == "*" {
                return array
            }
            if let idx = Int(inside), idx >= 0, idx < array.count {
                return array[idx]
            }
            return NSNull()
        }

        // 字典取值
        if let dict = current as? [String: Any] {
            return dict[token] ?? NSNull()
        }
        // JSONPath 允许在通配数组后继续取字段，例如 $.data[*].name。
        // Legado 会把后续字段映射到每个数组元素，而不是把整个数组视为字典。
        if let array = current as? [Any] {
            let values = array.compactMap { item -> Any? in
                guard let dict = item as? [String: Any], let value = dict[token] else { return nil }
                return value
            }
            return values.isEmpty ? NSNull() : values
        }
        return NSNull()
    }

    private static func recursiveSearch(_ node: Any, forTokens tokens: [String]) -> [Any] {
        var results: [Any] = []
        guard let first = tokens.first else { return [] }
        let rest = Array(tokens.dropFirst())

        func visit(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let match = dict[first] {
                    if rest.isEmpty {
                        results.append(match)
                    } else {
                        results.append(contentsOf: collect(match, remaining: rest))
                    }
                }
                for (_, v) in dict {
                    visit(v)
                }
            } else if let array = value as? [Any] {
                for v in array {
                    visit(v)
                }
            }
        }

        visit(node)
        return results
    }

    private static func collect(_ value: Any, remaining: [String]) -> [Any] {
        guard let first = remaining.first else { return [value] }
        let rest = Array(remaining.dropFirst())
        if let dict = value as? [String: Any] {
            if let next = dict[first] {
                return collect(next, remaining: rest)
            }
        }
        return []
    }

    /// 判断值是否为空（nil / NSNull / 空串 / 空数组 / 空字典）。
    static func isEmpty(_ value: Any?) -> Bool {
        guard let value else { return true }
        if value is NSNull { return true }
        if let s = value as? String { return s.isEmpty }
        if let a = value as? [Any] { return a.isEmpty }
        if let d = value as? [String: Any] { return d.isEmpty }
        return false
    }

    /// 将值规整为字符串。
    static func stringify(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            return n.stringValue
        }
        if let array = value as? [Any] {
            let parts = array.compactMap { stringify($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ",")
        }
        if let dict = value as? [String: Any], !dict.isEmpty {
            return String(data: (try? JSONSerialization.data(withJSONObject: dict)) ?? Data(), encoding: .utf8)
        }
        return "\(value)"
    }

    /// 将 JSON 反序列化结果转为数组（bookList 用）。
    static func asArray(_ value: Any?) -> [Any] {
        guard let value else { return [] }
        if let array = value as? [Any] { return array }
        if value is NSNull { return [] }
        if let dict = value as? [String: Any], dict.isEmpty { return [] }
        return [value]
    }
}
