//
//  RateLimiter.swift
//  BookSourceFetcher
//
//  基于书源 concurrentRate 字段的请求限速器。
//  Legado 格式："1/3" = 1 次请求 / 3 秒，"5/60" = 5 次 / 60 秒。
//

import Foundation

/// 按域名限速的请求调度器。
final class RateLimiter: Sendable {
    /// 每个域名的限速配置：(maxRequests, perSeconds)。
    private let limits: [String: (max: Int, seconds: TimeInterval)]
    /// 每个域名的请求时间戳记录。
    private nonisolated(unsafe) var timestamps: [String: [TimeInterval]] = [:]
    private let lock = NSLock()

    /// 从书源列表解析所有限速规则。
    init(sources: [PaquBookSource]) {
        var parsed: [String: (max: Int, seconds: TimeInterval)] = [:]
        for source in sources {
            guard let rate = source.concurrentRate, !rate.isEmpty,
                  let host = source.host else { continue }
            // 格式："maxRequests/seconds"
            let parts = rate.components(separatedBy: "/")
            guard parts.count == 2,
                  let max = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let seconds = TimeInterval(parts[1].trimmingCharacters(in: .whitespaces)),
                  max > 0, seconds > 0 else { continue }
            parsed[host] = (max: max, seconds: seconds)
        }
        self.limits = parsed
    }

    /// 等待直到该域名允许下一次请求（无限制的域名立即返回）。
    func waitIfNeeded(for host: String) async {
        guard let limit = limits[host] else { return }

        while true {
            let waitTime: TimeInterval? = lock.locked {
                let now = Date.timeIntervalSinceReferenceDate
                var ts = timestamps[host] ?? []

                // 清除过期时间戳
                ts = ts.filter { now - $0 < limit.seconds }

                if ts.count >= limit.max {
                    // 需要等最早的时间戳过期
                    let oldest = ts.min() ?? now
                    let wait = limit.seconds - (now - oldest) + 0.05
                    timestamps[host] = ts
                    return max(wait, 0.05)
                } else {
                    ts.append(now)
                    timestamps[host] = ts
                    return nil
                }
            }

            guard let waitTime else { return }
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
