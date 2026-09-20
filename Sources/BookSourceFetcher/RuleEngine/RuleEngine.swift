//
//  RuleEngine.swift
//  BookSourceFetcher
//
//  Legado 规则 DSL 求值引擎。
//  支持：CSS 选择器(@text/@href/@src/@textNodes/@html)、JSONPath($.x)、
//       正则 ##pattern##replacement、&& 拼接、|| 或、{{key}} 模板、@js JS 规则。
//

import Foundation
import SwiftSoup
import JavaScriptCore

/// 规则求值的上下文。承载搜索关键词、页码、当前解析对象等。
/// 注意：Element / Any 非 Sendable，此处仅在本包内单线程使用。
struct RuleContext {
    let key: String
    let page: Int
    let baseURL: URL?
    /// 当前元素（CSS 规则作用域，通常是一个搜索结果项）。
    let element: Element?
    /// 当前 JSON 对象（JSONPath 规则作用域）。
    let json: Any?
    /// JSON 根（bookUrl 等规则引用 $.id 时用）。
    let jsonRoot: Any?
    /// @put/@get 跨规则变量存储（同一规则链内共享）。
    var variables: [String: String]
    /// 复用的 JS 运行时（可选）。沿求值链传递，供 @js/<js> 规则复用同一 JSContext，
    /// 避免每次求值新建 context（内存驻留根因）。为 nil 时 @js 规则退化为新建（详情/测试路径）。
    let runtime: JSRuntime?

    init(key: String = "", page: Int = 1, baseURL: URL? = nil,
         element: Element? = nil, json: Any? = nil, jsonRoot: Any? = nil,
         variables: [String: String] = [:], runtime: JSRuntime? = nil) {
        self.key = key
        self.page = page
        self.baseURL = baseURL
        self.element = element
        self.json = json
        self.jsonRoot = jsonRoot
        self.variables = variables
        self.runtime = runtime
    }

    /// 派生一个以给定元素为作用域的上下文。
    func scoped(to element: Element?) -> RuleContext {
        RuleContext(key: key, page: page, baseURL: baseURL,
                    element: element, json: json, jsonRoot: jsonRoot,
                    variables: variables, runtime: runtime)
    }

    func scoped(toJSON json: Any?) -> RuleContext {
        RuleContext(key: key, page: page, baseURL: baseURL,
                    element: element, json: json, jsonRoot: jsonRoot,
                    variables: variables, runtime: runtime)
    }
}

/// 规则求值结果：可能是单个元素、一组元素、或一个字符串。
enum RuleResult {
    case none
    case elements([Element])
    case json(Any?)
    case string(String)
}

/// 规则求值器。
enum RuleEngine {

    // MARK: - 入口：求值一条规则，返回字符串

    /// 求值一条规则，返回字符串结果。
    static func evaluate(_ rule: String?, in context: RuleContext) -> String? {
        guard let rule, !rule.isEmpty else { return nil }
        context.runtime?.bind(context)
        guard let result = parse(rule, in: context) else { return nil }
        return stringify(result)
    }

    /// 求值一条规则，返回 RuleResult（供 init 等需要原始结果的场景使用）。
    static func parseRule(_ rule: String, in context: RuleContext) -> RuleResult? {
        context.runtime?.bind(context)
        return parse(rule, in: context)
    }

    /// 将 RuleResult 转成字符串。
    private static func stringify(_ result: RuleResult) -> String? {
        switch result {
        case .string(let s): return s
        case .json(let v): return JSONPath.stringify(v)
        case .elements(let els): return els.first.flatMap { try? $0.text() }
        case .none: return nil
        }
    }

    /// 求值一条规则，返回元素列表（bookList 用）。
    static func evaluateElements(_ rule: String?, in context: RuleContext) -> [Element] {
        guard let rule, !rule.isEmpty else { return [] }
        context.runtime?.bind(context)
        let parsed = parse(rule, in: context)
        guard let result = parsed else { return [] }
        switch result {
        case .elements(let els): return els
        default:
            if context.json == nil, case .elements(let els) = evaluateCSS(rule, in: context) { return els }
            return []
        }
    }

    /// 求值一条规则，返回 JSON 对象列表（bookList 用）。
    static func evaluateJSONList(_ rule: String?, in context: RuleContext) -> [Any] {
        guard let rule, !rule.isEmpty else { return [] }
        context.runtime?.bind(context)
        guard let result = parse(rule, in: context) else { return [] }
        switch result {
        case .json(let value): return JSONPath.asArray(value)
        case .string(let s):
            // 尝试反序列化为 JSON
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                return JSONPath.asArray(obj)
            }
            return []
        default: return []
        }
    }

    // MARK: - 顶层解析

    /// 解析规则，返回求值结果。
    private static func parse(_ rule: String, in context: RuleContext) -> RuleResult? {
        var ctx = context
        return parseMut(rule, in: &ctx)
    }

    /// 可变版本：支持 @put 修改上下文变量。
    private static func parseMut(_ rule: String, in context: inout RuleContext) -> RuleResult? {
        var r = rule

        if r.contains("{{") {
            let outside = r.replacingOccurrences(of: #"\{\{[\s\S]*?\}\}"#, with: "", options: .regularExpression)
            r = expandTemplate(r, in: context)
            if !["@js:", "<js>", "##", "&&", "||"].contains(where: { outside.contains($0) }) { return .string(r) }
        }

        if r.hasPrefix("@CSS:") { return evaluateCSS(String(r.dropFirst(5)), in: context) }
        if r.hasPrefix("@@") { return evaluateCSS(String(r.dropFirst(2)), in: context) }
        if r.hasPrefix("@Json:") { return parse(String(r.dropFirst(6)), in: context) }

        // Split scripts before operators/regex: JS itself can contain &&, || and ##.
        if let marker = r.range(of: "@js:"), marker.lowerBound != r.startIndex {
            let input = parse(String(r[..<marker.lowerBound]), in: context)
            let runtime = context.runtime ?? JSRuntime()
            switch input {
            case .json(let value): runtime.setObject(value ?? NSNull(), forKeyedSubscript: "result")
            default: runtime.setVariable("result", value: input.flatMap(stringify) ?? "")
            }
            return runtime.run(String(r[marker.upperBound...]), key: context.key, page: context.page, baseURL: context.baseURL?.absoluteString).map { .string($0) }
        }
        if let start = r.range(of: "<js>"), let end = r.range(of: "</js>", range: start.upperBound..<r.endIndex) {
            let runtime = context.runtime ?? JSRuntime()
            let head = String(r[..<start.lowerBound])
            if !head.isEmpty {
                let input = parse(head, in: context)
                switch input {
                case .json(let object): runtime.setObject(object ?? NSNull(), forKeyedSubscript: "result")
                default: runtime.setVariable("result", value: input.flatMap(stringify) ?? "")
                }
            }
            guard let result = runtime.run(String(r[start.upperBound..<end.lowerBound]), key: context.key, page: context.page, baseURL: context.baseURL?.absoluteString) else { return nil }
            let tail = String(r[end.upperBound...])
            guard !tail.isEmpty else { return .string(result) }
            if let object = try? JSONSerialization.jsonObject(with: Data(result.utf8)) { return parse(tail, in: context.scoped(toJSON: object)) }
            return parse(tail, in: context.scoped(to: try? SwiftSoup.parseBodyFragment(result)))
        }

        // 1. 处理 @js: 前缀（整条规则是 JS）
        if r.hasPrefix("@js:") {
            let js = String(r.dropFirst(4))
            let result = JSRunner.run(js, context: context)
            if let s = result { return .string(s) }
            return nil
        }

        // 1b. 处理 @XPath: 前缀（Legado XPath 规则）
        if r.hasPrefix("@XPath:") {
            let xpath = String(r.dropFirst(7))
            return evaluateXPath(xpath, in: context)
        }

        // 1c. 处理 @get:{key} 变量读取
        if r.hasPrefix("@get:{") && r.hasSuffix("}") {
            let key = String(r.dropFirst(6).dropLast(1))
            let value = context.runtime?.storage[key] ?? context.variables[key] ?? ""
            return value.isEmpty ? nil : .string(value)
        }

        // 1d. 处理 @put:{key} 变量存储（存值后返回空，但需要级联后续规则）
        if r.hasPrefix("@put:{"), let end = r.firstIndex(of: "}") {
            let literal = String(r[r.index(r.startIndex, offsetBy: 5)...end])
            let runtime = context.runtime ?? JSRuntime()
            if let entries = runtime.parseObject(literal) {
                for (key, expression) in entries {
                    let val = parse("\(expression)", in: context).flatMap(stringify) ?? ""
                    context.variables[key] = val
                    runtime.put(key, val)
                }
            } else {
                let inner = String(r[r.index(r.startIndex, offsetBy: 6)..<end])
                if let colon = inner.firstIndex(of: ":") {
                    let key = String(inner[..<colon]).trimmingCharacters(in: .whitespaces)
                    let expression = String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    let val = parse(expression, in: context).flatMap(stringify) ?? ""
                    context.variables[key] = val
                    runtime.put(key, val)
                }
            }
            let tail = String(r[r.index(after: end)...])
            return tail.isEmpty ? .string("") : parseMut(tail, in: &context)
        }

        // 2. 处理 <js>...</js> 整条规则
        if r.hasPrefix("<js>") && r.hasSuffix("</js>") {
            let js = String(r.dropFirst(4).dropLast(5))
            let result = JSRunner.run(js, context: context)
            if let s = result { return .string(s) }
            return nil
        }

        // 3. 处理 || 或规则（JSONPath 场景，如 $.data.novel_list||$.data）
        //    注意：CSS 里也可能出现 ||，但较少；优先在顶层做或解析。
        if r.contains("||") {
            let parts = r.components(separatedBy: "||")
            for part in parts {
                if let result = parse(part, in: context) {
                    if case .none = result { continue }
                    return result
                }
            }
            return nil
        }

        // 4. 处理 && 链式规则（Legado 语义：前一个结果作为下一个的输入上下文）
        if r.contains("&&") {
            let parts = r.components(separatedBy: "&&")
            let results = parts.compactMap { parse($0.trimmingCharacters(in: .whitespacesAndNewlines), in: context) }
            if results.allSatisfy({ if case .elements = $0 { return true }; return false }) {
                return .elements(results.flatMap { if case .elements(let els) = $0 { return els }; return [] })
            }
            if results.allSatisfy({ if case .json = $0 { return true }; return false }) {
                return .json(results.flatMap { result -> [Any] in
                    if case .json(let value) = result { return JSONPath.asArray(value) }
                    return []
                })
            }
            return .string(results.compactMap(stringify).joined(separator: "\n"))
        }

        // 5. 处理 ## 正则替换
        if r.range(of: "##") != nil {
            let parts = r.components(separatedBy: "##")
            let head = parts[0]
            guard let baseResult = parse(head, in: context) else { return nil }
            let baseString: String?
            switch baseResult {
            case .string(let s): baseString = s
            case .json(let v): baseString = JSONPath.stringify(v)
            case .elements(let els): baseString = els.first.flatMap { try? $0.text() }
            case .none: baseString = nil
            }
            guard var value = baseString else { return nil }

            // 后续每两个 token 一组：pattern, replacement
            var i = 1
            while i < parts.count {
                let pattern = parts[i]
                let replacement = i + 1 < parts.count ? parts[i + 1] : ""
                value = applyRegex(pattern, replacement: replacement, to: value)
                i += 2
            }

            // 如果最终值包含 @js: 表达式，清理/执行
            if value.contains("@js:") {
                value = evaluateInlineJS(value, context: context)
            }

            return .string(value)
        }

        // 6. 处理 {{...}} 模板变量（先替换为上下文值）
        r = expandTemplate(r, in: context)

        // 7. JSONPath 规则（以 $ 开头，或 JSON 场景下的裸字段路径如 "data.books"/"original_title"）
        if r.hasPrefix("$") {
            // bookUrl 等可能形如 "/novels/api/book/{{$.book_id}}" 或 "https://...{{$.id}}"
            if r.contains("{{") {
                // 已在上一步展开
                return .string(r)
            }
            let value = JSONPath.evaluate(r, root: context.json ?? context.jsonRoot ?? NSNull())
            if JSONPath.isEmpty(value) { return nil }
            return .json(value)
        }
        // JSON 场景下，裸字段路径当作 JSONPath（如 "data.books"、"original_title"、"image_link"）
        let jsonRoot = context.json ?? context.jsonRoot
        if jsonRoot != nil, looksLikeJSONPath(r) {
            let value = JSONPath.evaluate("$." + r, root: jsonRoot!)
            return JSONPath.isEmpty(value) ? nil : .json(value)
        }

        // 8. CSS 选择器规则
        if let element = context.element, ["text", "textNodes", "ownText", "html", "all", "href", "src", "content"].contains(r) {
            return extractAttribute(r, from: element, in: context)
        }
        if looksLikeCSS(r) {
            return evaluateCSS(r, in: context)
        }

        // 9. 纯字符串 / URL
        return .string(r)
    }

    /// 判断是否像纯字段路径（JSONPath 无 $ 前缀）：字母/下划线开头，只含字母数字下划线点括号星号。
    private static func looksLikeJSONPath(_ s: String) -> Bool {
        if s.contains("{{") || s.contains("##") || s.contains("&&") || s.contains("||")
            || s.contains("@") || s.contains(" ") || s.contains(",") || s.contains("/") {
            return false
        }
        let pattern = #"^[a-zA-Z_][a-zA-Z0-9_.\[\]\*]*$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - XPath 求值

    /// 用 XPath 选择器选取元素（Legado @XPath: 规则）。
    private static func evaluateXPath(_ xpath: String, in context: RuleContext) -> RuleResult? {
        guard let scope = context.element else { return nil }
        let elements = XPathEngine.evaluate(xpath, in: scope)
        if elements.isEmpty { return nil }
        return .elements(elements)
    }

    // MARK: - CSS 求值

    private static func looksLikeCSS(_ rule: String) -> Bool {
        // 包含 @属性 指令，或以 . # 开头，或是标签选择器
        if rule.contains("@") { return true }
        let first = rule.first ?? " "
        if first == "." || first == "#" || first == "[" { return true }
        // tag.class 形式，如 a.1、li.2
        if rule.range(of: #"^[a-zA-Z][a-zA-Z0-9]*[\.#]"#, options: .regularExpression) != nil {
            return true
        }
        // 纯标签如 "img" 且后面带 @
        return false
    }

    private static func evaluateCSS(_ rule: String, in context: RuleContext) -> RuleResult? {
        // 分离出 @ 指令部分
        // 形如："a.1@href"、"img@src"、".soft_info_r@a.0@text"、".s5,.s6@text"
        guard let atIndex = rule.firstIndex(of: "@") else {
            // 无 @ 指令，作为纯选择器返回元素列表
            let selector = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            return selectElements(selector, in: context)
        }

        let selector = String(rule[..<atIndex])
        let attribute = String(rule[rule.index(after: atIndex)...])

        // 属性可能是嵌套选择器（如 .soft_info_r@a.0@text 里的 a.0），递归处理
        let selected: RuleResult? = selector.isEmpty ? context.element.map { .elements([$0]) } : selectElements(selector, in: context)
        guard case .elements(let els) = selected, !els.isEmpty else { return nil }
        let terminal = ["text", "textNodes", "ownText", "html", "all", "href", "src", "data-src", "class", "id", "value", "content"]
        if terminal.contains(attribute) {
            let values = els.compactMap { extractAttribute(attribute, from: $0, in: context).flatMap(stringify) }
            return values.isEmpty ? nil : .string(values.joined(separator: "\n"))
        }
        if !attribute.contains("@") {
            let children = els.flatMap { element -> [Element] in
                if case .elements(let found) = selectElements(attribute, in: context.scoped(to: element)) { return found }
                return []
            }
            if !children.isEmpty { return .elements(children) }
            let values = els.compactMap { try? $0.attr(attribute) }.filter { !$0.isEmpty }
            return values.isEmpty ? nil : .string(values.joined(separator: "\n"))
        }
        let results = els.compactMap { evaluateCSS(attribute, in: context.scoped(to: $0)) }
        if results.allSatisfy({ if case .elements = $0 { return true }; return false }) {
            return .elements(results.flatMap { if case .elements(let elements) = $0 { return elements }; return [] })
        }
        return .string(results.compactMap(stringify).joined(separator: "\n"))
    }

    /// 用 CSS 选择器选取元素。支持逗号多选择器、tag.n 索引语法、空格后代、> 子元素。
    static func selectElements(_ selector: String, in context: RuleContext) -> RuleResult? {
        guard let scope = context.element else { return nil }

        let selectorStr = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectorStr.isEmpty else { return nil }

        // 逗号多选择器：取第一个有结果的
        let selectors = selectorStr.components(separatedBy: ",")
        for sel in selectors {
            var s = sel.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("id.") { s = "#" + s.dropFirst(3) }
            else if s.hasPrefix("class.") { s = "." + s.dropFirst(6) }
            else if s.hasPrefix("tag.") { s = String(s.dropFirst(4)) }
            guard !s.isEmpty else { continue }

            // 处理 Legado 的 "tag.n" 索引语法（n 为 0-based），如 "a.1"、"td.2"
            // 也处理 ".class" 但不能把 ".class" 误当索引
            if let (base, index) = parseIndexSelector(s) {
                do {
                    let els = try scope.select(base).array()
                    if index >= 0, index < els.count {
                        return .elements([els[index]])
                    }
                } catch {
                    continue
                }
            } else {
                do {
                    let els = try scope.select(s).array()
                    if !els.isEmpty {
                        return .elements(els)
                    }
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    /// 把形如 "tag.n"（n 是 0-based 索引）的选择器拆开。
    /// 返回 (tag, n)，若不匹配返回 nil。".class"、"tag#id"、"tag.class" 不拆分。
    private static func parseIndexSelector(_ selector: String) -> (base: String, index: Int)? {
        // 匹配以 \..?<数字> 结尾的形式，且数字前的基部分不是纯 class 选择器
        let pattern = #"^(.+)\.(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(selector.startIndex..<selector.endIndex, in: selector)
        guard let match = regex.firstMatch(in: selector, range: range) else { return nil }
        guard let baseRange = Range(match.range(at: 1), in: selector),
              let numRange = Range(match.range(at: 2), in: selector),
              let num = Int(String(selector[numRange])) else {
            return nil
        }
        let base = String(selector[baseRange])
        // 若 base 以 "#"、"[" 开头或是空，不应拆分；".class" 不应拆分
        if base.isEmpty || base.hasPrefix(".") || base.hasPrefix("#") { return nil }
        return (base, num)
    }

    /// 从元素提取属性/文本。attribute 可能是 @text/@href/@src/@textNodes/@html，
    /// 也可能是嵌套选择器（如 a.0@text、img、li.6）。
    private static func extractAttribute(_ attribute: String, from element: Element, in context: RuleContext) -> RuleResult? {
        let attr = attribute.trimmingCharacters(in: .whitespacesAndNewlines)

        // 特殊处理 @js: 前缀 — 直接执行 JS（不是嵌套 CSS 选择器）
        if attr.hasPrefix("@js:") {
            let jsCode = String(attr.dropFirst(4))
            let subCtx = context.scoped(to: element)
            let runtime = context.runtime ?? JSRuntime()
            runtime.put("result", (try? element.text()) ?? "")
            if let jsResult = runtime.run(jsCode, key: subCtx.key, page: subCtx.page, baseURL: subCtx.baseURL?.absoluteString) {
                return .string(jsResult)
            }
            return nil
        }

        // 若 attr 本身还包含 @，说明是嵌套选择器链（如 a.0@text）
        // 但要排除 @js: 前缀（已处理）
        if let nextAt = attr.firstIndex(of: "@") {
            let subSelector = String(attr[..<nextAt])
            let subAttr = String(attr[attr.index(after: nextAt)...])

            // 嵌套链中遇到 js: 前缀 → 执行 JS
            if subAttr.hasPrefix("js:") {
                let jsCode = String(subAttr.dropFirst(3))
                let runtime = context.runtime ?? JSRuntime()
                runtime.put("result", (try? element.text()) ?? "")
                if let jsResult = runtime.run(jsCode, key: context.key, page: context.page, baseURL: context.baseURL?.absoluteString) {
                    return .string(jsResult)
                }
                return nil
            }

            let subCtx = context.scoped(to: element)
            let selected = selectElements(subSelector, in: subCtx)
            guard let first = selected.flatMap({ result -> Element? in
                if case .elements(let els) = result { return els.first }
                return nil
            }) else { return nil }
            return extractAttribute(subAttr, from: first, in: context)
        }

        switch attr {
        case "text":
            return .string((try? element.text()) ?? "")
        case "textNodes", "ownText":
            return .string(element.ownText())
        case "html", "all":
            return .string((try? element.html()) ?? "")
        case "href":
            let href = (try? element.attr("href")) ?? ""
            return href.isEmpty ? nil : .string(href)
        case "src":
            let src = (try? element.attr("src")) ?? ""
            return src.isEmpty ? nil : .string(src)
        case "data-src":
            let src = (try? element.attr("data-src")) ?? ""
            return src.isEmpty ? nil : .string(src)
        case "class":
            let cls = (try? element.className()) ?? ""
            return cls.isEmpty ? nil : .string(cls)
        case "id":
            let id = element.id()
            return id.isEmpty ? nil : .string(id)
        case "value":
            let v = (try? element.val()) ?? ""
            return v.isEmpty ? nil : .string(v)
        case "content":
            let c = (try? element.attr("content")) ?? ""
            return c.isEmpty ? nil : .string(c)
        default:
            // 属性名可能是嵌套的标签选择器（无 @ 后缀，如 .toplist@li 里的 li）
            // 作为 CSS 选择器在元素内再选
            let subCtx = context.scoped(to: element)
            let selected = selectElements(attr, in: subCtx)
            if case .elements(let els) = selected, let first = els.first {
                return .string((try? first.text()) ?? "")
            }
            return nil
        }
    }

    // MARK: - 正则替换

    private static func applyRegex(_ pattern: String, replacement: String, to value: String) -> String {
        guard !pattern.isEmpty else { return value }
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            let result = regex.stringByReplacingMatches(
                in: value, options: [], range: range, withTemplate: replacement
            )
            return result
        } catch {
            // 正则非法时忽略
            return value
        }
    }

    /// 清理字符串中内嵌的 @js: 块。
    private static func evaluateInlineJS(_ text: String, context: RuleContext) -> String {
        var result = text

        // 如果整个字符串就是 @js: 开头，执行 JS
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@js:") {
            let js = String(trimmed.dropFirst(4))
            let runtime = context.runtime ?? JSRuntime()
            runtime.setVariable("result", value: result)
            if let jsResult = runtime.run(js, key: context.key, page: context.page, baseURL: context.baseURL?.absoluteString) {
                return jsResult
            }
        }

        // 收集所有 @js:... 块的范围，从后往前移除
        var rangesToRemove: [Range<String.Index>] = []
        var searchFrom = result.startIndex
        while searchFrom < result.endIndex,
              let jsRange = result.range(of: "@js:", range: searchFrom..<result.endIndex) {
            var depth = 0
            var removeEnd = result.endIndex
            var found = false
            var idx = jsRange.upperBound
            var inStr = false
            var strCh: Character = "\""
            while idx < result.endIndex {
                let ch = result[idx]
                if inStr {
                    if ch == strCh { inStr = false }
                } else {
                    if ch == "\"" || ch == "'" { inStr = true; strCh = ch }
                    else if ch == "(" { depth += 1 }
                    else if ch == ")" {
                        depth -= 1
                        if depth == 0 { removeEnd = result.index(after: idx); found = true; break }
                    }
                }
                idx = result.index(after: idx)
            }
            rangesToRemove.append(jsRange.lowerBound..<removeEnd)
            if found { searchFrom = removeEnd } else { break }
        }
        for range in rangesToRemove.reversed() {
            result.removeSubrange(range)
        }
        return result
    }

    /// 将 Swift 字符串转为 JS 字符串字面量。
    private static func javaStringLiteral(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{200B}", with: "")
        return "'\(escaped)'"
    }

    // MARK: - 模板变量 {{...}}

    private static func expandTemplate(_ rule: String, in context: RuleContext) -> String {
        guard rule.contains("{{") else { return rule }
        var result = rule
        let pattern = #"\{\{([\s\S]*?)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return rule }
        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = regex.matches(in: result, options: [], range: nsRange)

        // 从后往前替换，避免 range 偏移
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let inner = String(result[range])
            let token = String(inner.dropFirst(2).dropLast(2))
            let value = resolveTemplateToken(token, in: context)
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    private static func resolveTemplateToken(_ token: String, in context: RuleContext) -> String {
        switch token {
        case "key":
            return context.key
        case "page":
            return "\(context.page)"
        case "page-1":
            return "\(context.page - 1)"
        case "page+1":
            return "\(context.page + 1)"
        default:
            // {{$.id}} 从 JSON 取值
            if token.hasPrefix("$") {
                return parse(token, in: context).flatMap(stringify) ?? ""
            }
            // {{cookie.removeCookie(...)}} 等书源扩展，忽略
            if token.contains("cookie.") || token.contains("source.") {
                return ""
            }
            return JSRunner.run(token, context: context) ?? ""
        }
    }
}
