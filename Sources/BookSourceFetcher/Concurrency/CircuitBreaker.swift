//
//  CircuitBreaker.swift
//  BookSourceFetcher
//
//  源级熔断器：连续失败达到阈值的源进入冷却期，期间直接跳过，
//  避免每次搜索都去撞一遍已失效/慢挂起的源，让后续搜索延迟持续下降。
//
//  熔断状态持久化到 UserDefaults（跨 App 重启保持），
//  使"某源长期不可用"的信号在多次搜索会话间累积。
//

import Foundation

/// 按源 id（bookSourceName）记录失败并熔断。
public actor CircuitBreaker {
    /// 连续失败次数阈值，达到后进入冷却。
    private let failureThreshold: Int
    /// 冷却时长（秒）。
    private let cooldown: TimeInterval
    /// UserDefaults 存储键（区分不同 App 实例）。
    private let storageKey: String

    private var consecutiveFailures: [String: Int] = [:]
    private var openUntil: [String: Date] = [:]

    public init(
        failureThreshold: Int = 3,
        cooldown: TimeInterval = 120,
        storageKey: String = "com.rivulet.circuitbreaker"
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldown = max(0, cooldown)
        self.storageKey = storageKey
        if let state = Self.loadFromDisk(storageKey: storageKey) {
            consecutiveFailures = state.consecutiveFailures
            let now = Date()
            openUntil = state.openUntil.filter { $0.value > now }
        }
    }

    /// 该源当前是否允许发起请求（冷却中返回 false）。
    /// 冷却期已过时顺带清理记录，避免 `openUntil` 字典随时间无限增长。
    func allow(_ id: String) -> Bool {
        guard let until = openUntil[id] else { return true }
        if Date() >= until {
            openUntil.removeValue(forKey: id)
            consecutiveFailures.removeValue(forKey: id)
            saveToDisk()
            return true
        }
        return false
    }

    /// 记录一次请求结果。failed = true 表示源级失败（网络错误/非200/请求构建失败），
    /// 计入熔断；false 表示请求成功（可能 0 结果），重置连续失败计数。
    func record(_ id: String, failed: Bool) {
        if failed {
            let n = (consecutiveFailures[id] ?? 0) + 1
            if n >= failureThreshold {
                openUntil[id] = Date().addingTimeInterval(cooldown)
                consecutiveFailures[id] = 0
            } else {
                consecutiveFailures[id] = n
            }
        } else {
            consecutiveFailures[id] = 0
        }
        saveToDisk()
    }

    /// 重置所有源的熔断器（冷却期清零）。
    public func resetAll() {
        consecutiveFailures = [:]
        openUntil = [:]
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - 持久化

    private static let encoder = JSONEncoder()
    private struct PersistedState: Codable {
        let consecutiveFailures: [String: Int]
        let openUntil: [String: Date]
        let savedAt: Date
    }

    private static func loadFromDisk(storageKey: String) -> PersistedState? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func saveToDisk() {
        let state = PersistedState(
            consecutiveFailures: consecutiveFailures,
            openUntil: openUntil,
            savedAt: Date()
        )
        guard let data = try? Self.encoder.encode(state) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
