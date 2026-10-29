import Foundation

/// 消费后的定向读取使此前开始的批量/账号响应失效，只影响这个原生账号。
struct CodexResetRefreshFence {
    private(set) var token = 0
    private var invalidated: [String: Int] = [:]

    mutating func invalidate(_ identity: String) {
        token += 1
        invalidated[identity] = token
    }

    func accepts(_ startedAt: Int, identity: String) -> Bool {
        (invalidated[identity] ?? 0) <= startedAt
    }
}
