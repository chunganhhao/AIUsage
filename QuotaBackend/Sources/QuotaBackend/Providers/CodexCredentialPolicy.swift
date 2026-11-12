import CryptoKit
import Foundation

/// 一个用户在一个工作区中的订阅身份。名称、套餐和导入路径都不是原生身份。
public struct CodexAccountIdentity: Equatable, Sendable {
    public let accountId: String?
    public let userId: String?
    public let email: String?

    public init(accountId: String?, userId: String?, email: String? = nil) {
        self.accountId = Self.normalized(accountId)
        self.userId = Self.normalized(userId)
        let email = Self.normalized(email)
        self.email = email?.contains("@") == true ? email : nil
    }

    public init(credential: AccountCredential) {
        self.init(
            accountId: credential.metadata["accountId"],
            userId: Self.normalized(credential.metadata["workspaceUserId"]) ?? credential.metadata["userId"],
            email: Self.normalized(credential.metadata["accountEmail"])
                ?? Self.normalized(credential.metadata["accountHandle"]) ?? credential.accountLabel
        )
    }

    /// 同时支持 Codex 原生 auth.json 和 CPA 扁平文件；先取当前生效 token 组的用户原生 ID，最后才取 sub。
    public init(authJSON json: [String: Any]) {
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let flatAccess = (json["access_token"] ?? json["accessToken"]) as? String
        let nestedAccess = (tokens["access_token"] ?? tokens["accessToken"]) as? String
        let flatId = (json["id_token"] ?? json["idToken"]) as? String
        let nestedId = (tokens["id_token"] ?? tokens["idToken"]) as? String

        let hasFlatTokens = flatAccess != nil || flatId != nil
        let hasNestedTokens = nestedAccess != nil || nestedId != nil
        let preferFlat: Bool
        if hasFlatTokens && hasNestedTokens {
            preferFlat = Self.tokenIssuedAt(flatAccess) >= Self.tokenIssuedAt(nestedAccess)
        } else {
            preferFlat = hasFlatTokens
        }

        let rawIdToken = preferFlat ? (flatId ?? (hasFlatTokens ? nil : nestedId)) : (nestedId ?? (hasNestedTokens ? nil : flatId))
        let activeAccessToken = preferFlat ? (flatAccess ?? (hasFlatTokens ? nil : nestedAccess)) : (nestedAccess ?? (hasNestedTokens ? nil : flatAccess))
        let (accessIdentity, idTokenIdentity) = Self.tokenPairIdentities(activeAccessToken, rawIdToken)
        let internalConflict = activeAccessToken != nil && rawIdToken != nil && accessIdentity.conflicts(with: idTokenIdentity)
        if internalConflict {
            self.init(accountId: nil, userId: nil, email: nil)
            return
        }
        let activeIdToken = rawIdToken

        let claims = [activeIdToken, activeAccessToken].compactMap { Self.jwtPayload($0) }
        let auth = claims.compactMap { $0["https://api.openai.com/auth"] as? [String: Any] }
        func first(_ values: [Any?]) -> String? {
            values.lazy.compactMap { Self.normalized($0 as? String) }.first
        }
        let accountCandidates: [Any?] = preferFlat
            ? [json["account_id"], json["accountId"], json["chatgpt_account_id"], tokens["account_id"], tokens["accountId"]]
            : [tokens["account_id"], tokens["accountId"], json["account_id"], json["accountId"], json["chatgpt_account_id"]]
        let accountId = first(auth.map { $0["chatgpt_account_id"] } + claims.map { $0["chatgpt_account_id"] } + accountCandidates)
        let rootUserCandidates: [Any?] = internalConflict ? [] : [json["chatgpt_user_id"], json["user_id"]]
        let userId = first(auth.map { $0["chatgpt_user_id"] } + claims.map { $0["chatgpt_user_id"] }
            + auth.map { $0["user_id"] } + claims.map { $0["user_id"] }
            + rootUserCandidates + claims.map { $0["sub"] })
        let rootEmailCandidates: [Any?] = internalConflict ? [] : [json["email"]]
        let email = first(claims.map { $0["email"] }
            + claims.map { ($0["https://api.openai.com/profile"] as? [String: Any])?["email"] }
            + rootEmailCandidates)
        self.init(accountId: accountId, userId: userId, email: email)
    }

    static func tokenIdentity(_ token: String?, includeSubjectFallback: Bool = true) -> Self {
        guard let claim = jwtPayload(token) else {
            return Self(accountId: nil, userId: nil, email: nil)
        }
        let auth = claim["https://api.openai.com/auth"] as? [String: Any]
        func first(_ values: [Any?]) -> String? {
            values.lazy.compactMap { Self.normalized($0 as? String) }.first
        }
        let accountId = first([auth?["chatgpt_account_id"], claim["chatgpt_account_id"]])
        let userId = first([auth?["chatgpt_user_id"], claim["chatgpt_user_id"], auth?["user_id"], claim["user_id"],
                            includeSubjectFallback ? claim["sub"] : nil])
        let email = first([claim["email"], (claim["https://api.openai.com/profile"] as? [String: Any])?["email"]])
        return Self(accountId: accountId, userId: userId, email: email)
    }

    /// Native user IDs and legacy subjects are different namespaces. Compare subjects only
    /// when neither token has a native user ID; account and email guards still apply.
    static func tokenPairIdentities(_ accessToken: String?, _ idToken: String?) -> (access: Self, id: Self) {
        let access = tokenIdentity(accessToken, includeSubjectFallback: false)
        let id = tokenIdentity(idToken, includeSubjectFallback: false)
        if access.userId == nil && id.userId == nil {
            return (tokenIdentity(accessToken), tokenIdentity(idToken))
        }
        return (access, id)
    }

    private static func tokenIssuedAt(_ token: String?) -> Double {
        let payload = jwtPayload(token)
        return (payload?["iat"] as? Double) ?? (payload?["exp"] as? Double) ?? 0
    }

    public var nativeKey: String? {
        guard let accountId, let userId else { return nil }
        return "codex:account:\(accountId):user:\(userId)"
    }

    /// 旧数据缺少 userId 时，工作区 + 有效邮箱可用于关联；邮箱永远不能单独匹配。
    public var key: String? {
        if let nativeKey { return nativeKey }
        guard let accountId, let email else { return nil }
        return "codex:account:\(accountId):email:\(email)"
    }

    public func conflicts(with other: Self) -> Bool {
        if let accountId, let otherId = other.accountId, accountId != otherId { return true }
        if let userId, let otherUser = other.userId { return userId != otherUser }
        if let email, let otherEmail = other.email, email != otherEmail { return true }
        return false
    }

    public func matches(_ other: Self) -> Bool {
        guard !conflicts(with: other), let accountId, accountId == other.accountId else { return false }
        if let userId, let otherUser = other.userId { return userId == otherUser }
        return email != nil && email == other.email
    }

    /// 不完整身份的路径/UUID 回退也保留已知字段，防止同路径的不同账号碰撞。
    public func key(fallback: String) -> String {
        key ?? "codex:incomplete:account:\(accountId ?? "*"):user:\(userId ?? "*"):email:\(email ?? "*"):\(fallback)"
    }

    /// Extracts the case-preserving `(userId, accountId)` principal pair used by
    /// Codex Desktop (`ChatGPT.app`) `electron-account-renderer-state-v1`.
    public static func rendererPrincipal(fromAuthJSON json: [String: Any]) -> (userId: String, accountId: String)? {
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let flatAccess = (json["access_token"] ?? json["accessToken"]) as? String
        let nestedAccess = (tokens["access_token"] ?? tokens["accessToken"]) as? String
        let flatId = (json["id_token"] ?? json["idToken"]) as? String
        let nestedId = (tokens["id_token"] ?? tokens["idToken"]) as? String

        let hasFlatTokens = flatAccess != nil || flatId != nil
        let hasNestedTokens = nestedAccess != nil || nestedId != nil
        let preferFlat: Bool
        if hasFlatTokens && hasNestedTokens {
            preferFlat = Self.tokenIssuedAt(flatAccess) >= Self.tokenIssuedAt(nestedAccess)
        } else {
            preferFlat = hasFlatTokens
        }

        let rawIdToken = preferFlat ? (flatId ?? (hasFlatTokens ? nil : nestedId)) : (nestedId ?? (hasNestedTokens ? nil : flatId))
        let activeAccessToken = preferFlat ? (flatAccess ?? (hasFlatTokens ? nil : nestedAccess)) : (nestedAccess ?? (hasNestedTokens ? nil : flatAccess))
        let (accessIdentity, idTokenIdentity) = Self.tokenPairIdentities(activeAccessToken, rawIdToken)
        if activeAccessToken != nil && rawIdToken != nil && accessIdentity.conflicts(with: idTokenIdentity) {
            return nil
        }

        let claims = [rawIdToken, activeAccessToken].compactMap { Self.jwtPayload($0) }
        let auth = claims.compactMap { $0["https://api.openai.com/auth"] as? [String: Any] }
        func first(_ values: [Any?]) -> String? {
            values.lazy.compactMap { Self.trimmedCasePreserving($0 as? String) }.first
        }
        let accountCandidates: [Any?] = preferFlat
            ? [json["account_id"], json["accountId"], json["chatgpt_account_id"], tokens["account_id"], tokens["accountId"]]
            : [tokens["account_id"], tokens["accountId"], json["account_id"], json["accountId"], json["chatgpt_account_id"]]
        guard let accountId = first(auth.map { $0["chatgpt_account_id"] } + claims.map { $0["chatgpt_account_id"] } + accountCandidates),
              let userId = first(auth.map { $0["chatgpt_user_id"] } + claims.map { $0["chatgpt_user_id"] }
                  + auth.map { $0["user_id"] } + claims.map { $0["user_id"] }
                  + [json["chatgpt_user_id"], json["user_id"]] + claims.map { $0["sub"] }) else {
            return nil
        }
        return (userId: userId, accountId: accountId)
    }

    /// Computes `sha256(JSON.stringify([userId, accountId]))` matching Codex Desktop (`ChatGPT.app`).
    public static func rendererOwnerHash(userId: String?, accountId: String?) -> String? {
        guard let userId = trimmedCasePreserving(userId),
              let accountId = trimmedCasePreserving(accountId),
              let data = try? JSONSerialization.data(withJSONObject: [userId, accountId]) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func rendererOwnerHash(fromAuthJSON json: [String: Any]) -> String? {
        guard let principal = rendererPrincipal(fromAuthJSON: json) else { return nil }
        return rendererOwnerHash(userId: principal.userId, accountId: principal.accountId)
    }

    private static func trimmedCasePreserving(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalized(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased(), !normalized.isEmpty else { return nil }
        return normalized
    }

    fileprivate static func jwtPayload(_ token: String?) -> [String: Any]? {
        guard let pieces = token?.split(separator: "."), pieces.count >= 2 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public enum CodexGlobalStateSync {
    private static let rendererStateKey = "electron-account-renderer-state-v1"
    private static let persistedAtomStateKey = "electron-persisted-atom-state"
    private static let unownedTopSnapshotKey = "__top_unowned__"

    private static let projectBackingKeys: [String] = [
        "chatGptBacking",
        "chatGptBackingCreation",
        "chatGptBackingRecoveryPending"
    ]

    private static let accountLocalWorkspaceKeys: [String] = [
        "active-workspace-roots",
        "electron-saved-workspace-roots",
        "electron-workspace-root-labels"
    ]

    private static let flatDictionaryKeys: [String] = [
        "project-appearances",
        "sidebar-project-thread-orders",
        "thread-project-assignments",
        "thread-project-membership-host-ids",
        "thread-workspace-root-hints",
        "thread-projectless-output-directories",
        "app-server-projects-migration-by-host",
        "queued-follow-ups"
    ]

    private static let nestedHostDictionaryKeys: [String] = [
        "app-server-project-id-by-legacy-project-id-by-host"
    ]

    private static let nestedHostArrayKeys: [String] = [
        "app-server-migrated-pinned-thread-ids-by-host"
    ]

    private static let orderedArrayKeys: [String] = [
        "project-order",
        "pinned-thread-ids",
        "projectless-thread-ids",
        "pinned-project-ids"
    ]

    public struct SyncOutcome: Equatable, Sendable {
        public let wasTargetPreseeded: Bool
        public let projectCount: Int

        public init(wasTargetPreseeded: Bool, projectCount: Int) {
            self.wasTargetPreseeded = wasTargetPreseeded
            self.projectCount = projectCount
        }
    }

    /// Merges local workspace projects and thread-project assignments across top-level
    /// `~/.codex/.codex-global-state.json` and all `electron-account-renderer-state-v1.inactive`
    /// account snapshots so switching Codex accounts never hides local projects in Codex Desktop.
    ///
    /// - Parameters:
    ///   - codexDir: Path to `~/.codex`.
    ///   - targetOwnerHash: Target account renderer owner hash (`sha256(JSON.stringify([userId, accountId]))`).
    ///   - additionalOwnerHashes: Known inactive Codex account owner hashes to pre-seed.
    ///   - transitionOwner: When `false` (default), preserves the current active `owner` and keeps
    ///     `inactive[targetOwnerHash]` intact (overlaying only shared project fields). When `true`,
    ///     performs an explicit owner transition (`currentOwner -> targetOwnerHash`) that archives
    ///     `currentOwner`'s atoms/globals into `inactive[currentOwner]` and restores `targetOwnerHash`'s
    ///     atoms/globals to top-level.
    @discardableResult
    public static func syncWorkspaceProjects(
        codexDir: String,
        targetOwnerHash: String?,
        additionalOwnerHashes: Set<String> = [],
        transitionOwner: Bool = false
    ) -> SyncOutcome {
        let fm = FileManager.default
        let statePath = (codexDir as NSString).appendingPathComponent(".codex-global-state.json")
        let backupPath = statePath + ".bak"

        guard var state = loadStateObject(primaryPath: statePath, backupPath: backupPath, fm: fm) else {
            return SyncOutcome(wasTargetPreseeded: true, projectCount: 0)
        }

        let rendererState = state[rendererStateKey] as? [String: Any]
        let rawCurrentOwner = (rendererState?["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentOwner = (rawCurrentOwner?.isEmpty == false) ? rawCurrentOwner : nil
        let inactiveMap = rendererState?["inactive"] as? [String: Any] ?? [:]

        let rawTarget = targetOwnerHash?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTarget = (rawTarget?.isEmpty == false) ? rawTarget : nil

        var ownedSnapshots: [(ownerKey: String, globals: [String: Any])] = []
        for ownerKey in inactiveMap.keys.sorted() {
            if let entry = inactiveMap[ownerKey] as? [String: Any],
               let globals = entry["globals"] as? [String: Any] {
                ownedSnapshots.append((ownerKey: ownerKey, globals: globals))
            }
        }
        let topOwnerKey = currentOwner ?? normalizedTarget ?? unownedTopSnapshotKey
        ownedSnapshots.append((ownerKey: topOwnerKey, globals: state))
        let snapshots = ownedSnapshots.map(\.globals)

        var knownRendererOwnerKeys = Set(inactiveMap.keys)
        if let currentOwner {
            knownRendererOwnerKeys.insert(currentOwner)
        }
        if let normalizedTarget {
            knownRendererOwnerKeys.insert(normalizedTarget)
        }
        for hash in additionalOwnerHashes {
            let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                knownRendererOwnerKeys.insert(trimmed)
            }
        }

        var mergedBaseProjects: [String: [String: Any]] = [:]
        var ownerProjectBackings: [String: [String: [String: Any]]] = [:]

        for (ownerKey, snapshot) in ownedSnapshots {
            guard let projects = snapshot["local-projects"] as? [String: Any] else { continue }
            for (projectId, rawProject) in projects {
                guard var projectDict = rawProject as? [String: Any] else { continue }
                var backing: [String: Any] = [:]
                for bKey in projectBackingKeys {
                    if let bVal = projectDict.removeValue(forKey: bKey) {
                        backing[bKey] = bVal
                    }
                }
                if !backing.isEmpty {
                    let resolvedBackingOwner = resolveBackingOwnerKey(
                        backing: backing,
                        fallbackSnapshotOwnerKey: ownerKey,
                        knownRendererOwnerKeys: knownRendererOwnerKeys
                    )
                    var perOwner = ownerProjectBackings[resolvedBackingOwner] ?? [:]
                    perOwner[projectId] = backing
                    ownerProjectBackings[resolvedBackingOwner] = perOwner
                }
                if let existing = mergedBaseProjects[projectId] {
                    let existingUpdated = (existing["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                    let incomingUpdated = (projectDict["updatedAt"] as? NSNumber)?.doubleValue ?? 0
                    if incomingUpdated >= existingUpdated {
                        mergedBaseProjects[projectId] = projectDict
                    }
                } else {
                    mergedBaseProjects[projectId] = projectDict
                }
            }
        }

        guard !mergedBaseProjects.isEmpty else {
            return SyncOutcome(wasTargetPreseeded: true, projectCount: 0)
        }

        let wasTargetPreseeded: Bool = {
            guard let normalizedTarget else {
                let topProjects = state["local-projects"] as? [String: Any] ?? [:]
                return rendererState == nil && mergedBaseProjects.keys.allSatisfy { topProjects[$0] != nil }
            }
            if currentOwner == normalizedTarget {
                let topProjects = state["local-projects"] as? [String: Any] ?? [:]
                return mergedBaseProjects.keys.allSatisfy { topProjects[$0] != nil }
            }
            if let entry = inactiveMap[normalizedTarget] as? [String: Any],
               let globals = entry["globals"] as? [String: Any],
               let projects = globals["local-projects"] as? [String: Any] {
                return mergedBaseProjects.keys.allSatisfy { projects[$0] != nil }
            }
            return false
        }()

        var sharedNonProjectGlobals: [String: Any] = [:]

        for key in flatDictionaryKeys {
            var acc: [String: Any] = [:]
            for snapshot in snapshots {
                guard let dict = snapshot[key] as? [String: Any] else { continue }
                for (k, v) in dict { acc[k] = v }
            }
            if !acc.isEmpty || snapshots.contains(where: { $0[key] != nil }) {
                sharedNonProjectGlobals[key] = acc
            }
        }

        for key in nestedHostDictionaryKeys {
            var acc: [String: [String: Any]] = [:]
            for snapshot in snapshots {
                guard let hostDict = snapshot[key] as? [String: Any] else { continue }
                for (hostKey, rawInner) in hostDict {
                    guard let inner = rawInner as? [String: Any] else { continue }
                    var mergedInner = acc[hostKey] ?? [:]
                    for (ik, iv) in inner { mergedInner[ik] = iv }
                    acc[hostKey] = mergedInner
                }
            }
            if !acc.isEmpty {
                sharedNonProjectGlobals[key] = acc
            }
        }

        for key in nestedHostArrayKeys {
            var acc: [String: [String]] = [:]
            for snapshot in snapshots {
                guard let hostDict = snapshot[key] as? [String: Any] else { continue }
                for (hostKey, rawArr) in hostDict {
                    guard let arr = rawArr as? [String] else { continue }
                    var existing = acc[hostKey] ?? []
                    for item in arr where !existing.contains(item) {
                        existing.append(item)
                    }
                    acc[hostKey] = existing
                }
            }
            if !acc.isEmpty {
                sharedNonProjectGlobals[key] = acc
            }
        }

        for key in orderedArrayKeys {
            var ordered: [String] = []
            for snapshot in snapshots.reversed() {
                guard let arr = snapshot[key] as? [String] else { continue }
                for item in arr where !ordered.contains(item) {
                    ordered.append(item)
                }
            }
            if key == "project-order" {
                for pid in mergedBaseProjects.keys.sorted() where !ordered.contains(pid) {
                    ordered.append(pid)
                }
            }
            if !ordered.isEmpty || snapshots.contains(where: { $0[key] != nil }) {
                sharedNonProjectGlobals[key] = ordered
            }
        }

        for snapshot in snapshots.reversed() {
            if let selected = snapshot["selected-project"] as? [String: Any] {
                sharedNonProjectGlobals["selected-project"] = selected
                break
            }
        }

        if snapshots.contains(where: { ($0["remote-project-connection-backfill-completed"] as? Bool) == true }) {
            sharedNonProjectGlobals["remote-project-connection-backfill-completed"] = true
        }

        func projectsForOwner(_ ownerHash: String?) -> [String: [String: Any]] {
            let key = (ownerHash?.isEmpty == false) ? ownerHash! : topOwnerKey
            let backings = ownerProjectBackings[key] ?? [:]
            var result = mergedBaseProjects
            for (projectId, backing) in backings {
                guard var proj = result[projectId] else { continue }
                for (bKey, bVal) in backing {
                    proj[bKey] = bVal
                }
                result[projectId] = proj
            }
            return result
        }

        func sharedGlobals(forOwner ownerHash: String?) -> [String: Any] {
            var globals = sharedNonProjectGlobals
            globals["local-projects"] = projectsForOwner(ownerHash)
            return globals
        }

        if rendererState != nil || normalizedTarget != nil {
            var updatedInactive = inactiveMap
            var otherOwners = Set(inactiveMap.keys)
            if let currentOwner {
                otherOwners.insert(currentOwner)
            }
            if let normalizedTarget {
                otherOwners.insert(normalizedTarget)
            }
            for hash in additionalOwnerHashes {
                let trimmed = hash.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    otherOwners.insert(trimmed)
                }
            }

            let effectiveOwner: String? = {
                if transitionOwner {
                    return normalizedTarget ?? currentOwner
                }
                return currentOwner
            }()

            if transitionOwner,
               let normalizedTarget,
               currentOwner != normalizedTarget {
                // 1. Archive `currentOwner`'s active atoms and workspace globals into `updatedInactive[currentOwner]`.
                if let currentOwner {
                    var currentEntry = (updatedInactive[currentOwner] as? [String: Any]) ?? [:]
                    var currentAtoms = (currentEntry["atoms"] as? [String: Any]) ?? [:]
                    if let topAtoms = state[persistedAtomStateKey] as? [String: Any] {
                        for (ak, av) in topAtoms {
                            currentAtoms[ak] = av
                        }
                    }
                    currentEntry["atoms"] = currentAtoms

                    var currentGlobals = (currentEntry["globals"] as? [String: Any]) ?? [:]
                    for key in accountLocalWorkspaceKeys {
                        if let val = state[key] {
                            currentGlobals[key] = val
                        }
                    }
                    for (k, v) in sharedGlobals(forOwner: currentOwner) {
                        currentGlobals[k] = v
                    }
                    currentEntry["globals"] = currentGlobals
                    updatedInactive[currentOwner] = currentEntry
                }

                // 2. Restore `normalizedTarget`'s inactive snapshot (`atoms` + account-local `globals`) to top-level.
                let targetEntry = updatedInactive.removeValue(forKey: normalizedTarget) as? [String: Any]
                if let targetAtoms = targetEntry?["atoms"] as? [String: Any] {
                    state[persistedAtomStateKey] = targetAtoms
                } else if currentOwner != nil {
                    state.removeValue(forKey: persistedAtomStateKey)
                }

                for key in accountLocalWorkspaceKeys {
                    state.removeValue(forKey: key)
                }
                if let targetGlobals = targetEntry?["globals"] as? [String: Any] {
                    for (gk, gv) in targetGlobals {
                        state[gk] = gv
                    }
                }
            } else if let effectiveOwner,
                      let strayActiveEntry = updatedInactive.removeValue(forKey: effectiveOwner) as? [String: Any] {
                // If an entry for the already-active owner existed in `inactive`, merge its atoms/globals
                // into top-level without overwriting newer top-level values before removing the duplicate slot.
                if let strayAtoms = strayActiveEntry["atoms"] as? [String: Any] {
                    var mergedAtoms = strayAtoms
                    if let topAtoms = state[persistedAtomStateKey] as? [String: Any] {
                        for (ak, av) in topAtoms {
                            mergedAtoms[ak] = av
                        }
                    }
                    state[persistedAtomStateKey] = mergedAtoms
                }
                if let strayGlobals = strayActiveEntry["globals"] as? [String: Any] {
                    for (gk, gv) in strayGlobals where state[gk] == nil {
                        state[gk] = gv
                    }
                }
            }

            if let effectiveOwner {
                otherOwners.remove(effectiveOwner)
            }

            for (key, value) in sharedGlobals(forOwner: effectiveOwner) {
                state[key] = value
            }

            for ownerHash in otherOwners {
                var entry = (updatedInactive[ownerHash] as? [String: Any]) ?? [:]
                if entry["atoms"] == nil {
                    entry["atoms"] = [String: Any]()
                }
                var entryGlobals = (entry["globals"] as? [String: Any]) ?? [:]
                for (k, v) in sharedGlobals(forOwner: ownerHash) {
                    entryGlobals[k] = v
                }
                entry["globals"] = entryGlobals
                updatedInactive[ownerHash] = entry
            }

            var updatedRendererState = rendererState ?? [:]
            updatedRendererState["owner"] = effectiveOwner ?? NSNull()
            updatedRendererState["inactive"] = updatedInactive
            state[rendererStateKey] = updatedRendererState
        } else {
            for (key, value) in sharedGlobals(forOwner: nil) {
                state[key] = value
            }
        }

        if let serialized = try? JSONSerialization.data(withJSONObject: state) {
            try? serialized.write(to: URL(fileURLWithPath: statePath), options: .atomic)
            try? serialized.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
        }

        return SyncOutcome(wasTargetPreseeded: wasTargetPreseeded, projectCount: mergedBaseProjects.count)
    }

    /// Reconciles `~/.codex/.codex-global-state.json` after `~/.codex/auth.json` has been updated.
    /// If Codex Desktop (`com.openai.codex`) is running and wiped `local-projects` on an unseeded
    /// account switch, terminates it and waits for verified process exit before writing the final
    /// owner transition and relaunching. Fails closed if termination is refused or times out.
    @discardableResult
    public static func reconcileRunningCodexDesktop(
        codexDir: String,
        targetOwnerHash: String?,
        additionalOwnerHashes: Set<String> = [],
        syncOutcome: SyncOutcome,
        pollAttempts: Int = 25,
        pollIntervalNanoseconds: UInt64 = 150_000_000,
        isCodexRunning: () async -> Bool,
        requestTerminate: () async -> Bool,
        relaunchCodex: () async -> Void
    ) async -> Bool {
        guard !Task.isCancelled,
              isCurrentTargetStillAuthorized(codexDir: codexDir, targetOwnerHash: targetOwnerHash) else {
            return false
        }

        let statePath = (codexDir as NSString).appendingPathComponent(".codex-global-state.json")
        let topProjectsAfterSwitch: Int = {
            guard let data = FileManager.default.contents(atPath: statePath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let projects = json["local-projects"] as? [String: Any] else {
                return 0
            }
            return projects.count
        }()

        let currentlyRunning = await isCodexRunning()
        guard !Task.isCancelled,
              isCurrentTargetStillAuthorized(codexDir: codexDir, targetOwnerHash: targetOwnerHash) else {
            return false
        }

        if !currentlyRunning {
            _ = syncWorkspaceProjects(
                codexDir: codexDir,
                targetOwnerHash: targetOwnerHash,
                additionalOwnerHashes: additionalOwnerHashes,
                transitionOwner: true
            )
            return true
        }

        _ = syncWorkspaceProjects(
            codexDir: codexDir,
            targetOwnerHash: targetOwnerHash,
            additionalOwnerHashes: additionalOwnerHashes,
            transitionOwner: false
        )

        guard syncOutcome.projectCount > 0,
              (!syncOutcome.wasTargetPreseeded || topProjectsAfterSwitch == 0) else {
            return true
        }

        let terminateAccepted = await requestTerminate()
        guard terminateAccepted,
              !Task.isCancelled,
              isCurrentTargetStillAuthorized(codexDir: codexDir, targetOwnerHash: targetOwnerHash) else {
            return false
        }

        var exitedCleanly = false
        for _ in 0..<max(1, pollAttempts) {
            guard !Task.isCancelled else { return false }
            let runningNow = await isCodexRunning()
            guard !Task.isCancelled else { return false }
            if !runningNow {
                exitedCleanly = true
                break
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        // Fail closed if the old Codex Desktop process is still running after the poll window
        // or if a newer account activation superseded this reconciliation task.
        guard exitedCleanly,
              !Task.isCancelled,
              isCurrentTargetStillAuthorized(codexDir: codexDir, targetOwnerHash: targetOwnerHash) else {
            return false
        }

        _ = syncWorkspaceProjects(
            codexDir: codexDir,
            targetOwnerHash: targetOwnerHash,
            additionalOwnerHashes: additionalOwnerHashes,
            transitionOwner: true
        )

        guard !Task.isCancelled else { return false }
        await relaunchCodex()
        return true
    }

    private static func isCurrentTargetStillAuthorized(
        codexDir: String,
        targetOwnerHash: String?
    ) -> Bool {
        guard let rawTarget = targetOwnerHash?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTarget.isEmpty else {
            return true
        }
        let authPath = (codexDir as NSString).appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: authPath) else {
            return true
        }
        guard let data = FileManager.default.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let diskOwnerHash = CodexAccountIdentity.rendererOwnerHash(fromAuthJSON: json) else {
            return false
        }
        return diskOwnerHash == rawTarget
    }

    private static func resolveBackingOwnerKey(
        backing: [String: Any],
        fallbackSnapshotOwnerKey: String,
        knownRendererOwnerKeys: Set<String>
    ) -> String {
        if let bDict = backing["chatGptBacking"] as? [String: Any] {
            if let bUser = bDict["userId"] as? String,
               let bAcc = bDict["accountId"] as? String,
               let computedHash = CodexAccountIdentity.rendererOwnerHash(userId: bUser, accountId: bAcc) {
                return computedHash
            }
            if let bAcc = (bDict["accountId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bAcc.isEmpty,
               knownRendererOwnerKeys.contains(bAcc) {
                return bAcc
            }
        }
        return fallbackSnapshotOwnerKey
    }

    private static func loadStateObject(primaryPath: String, backupPath: String, fm: FileManager) -> [String: Any]? {
        for path in [primaryPath, backupPath] {
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return obj
        }
        return nil
    }
}

public enum CodexCredentialPolicy {
    public struct ReconciledAuthPayload: @unchecked Sendable {
        public let nativeData: Data
        public let nativeJSON: [String: Any]
        public let identity: CodexAccountIdentity
        public let adoptedLiveCandidate: Bool
        public let healedManagedData: Data?
        public let isValidBaseline: Bool
    }

    private static func invalidReconciledPayload() -> ReconciledAuthPayload {
        ReconciledAuthPayload(
            nativeData: Data(),
            nativeJSON: [:],
            identity: CodexAccountIdentity(accountId: nil, userId: nil, email: nil),
            adoptedLiveCandidate: false,
            healedManagedData: nil,
            isValidBaseline: false
        )
    }

    private struct ValidatedTokenGroup {
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let accountId: String
        let email: String?
        let identity: CodexAccountIdentity
        let lastRefreshRaw: String?
        let lastRefreshTime: TimeInterval?
        let expiredRaw: String?
        let expiredTime: TimeInterval?
        let accessIssuedAt: Double
    }

    private struct ParsedAuthSnapshot {
        let rawData: Data
        let rawJSON: [String: Any]
        let identity: CodexAccountIdentity
        let accessToken: String
        let refreshToken: String?
        let idToken: String?
        let accountId: String?
        let email: String?
        let lastRefreshRaw: String?
        let lastRefreshTime: TimeInterval?
        let expiredRaw: String?
        let expiredTime: TimeInterval?
        let accessIssuedAt: Double
        let isAlreadyCleanNative: Bool
    }

    /// Reconciles the managed auth payload for `expectedIdentity` against live candidate files
    /// (such as `~/.codex/auth.json` and `~/.codex/auth.json.bak`).
    /// - Fails closed (`isValidBaseline == false`, empty payload/identity) if the managed baseline
    ///   (or `managedSourceData` when provided) fails strict validation or does not match `expectedIdentity`.
    /// - Preserves/selects a candidate ONLY when it is a valid OAuth credential belonging to the
    ///   exact same `expectedIdentity` and is strictly newer than the managed copy.
    /// - Never adopts a candidate belonging to a different account or workspace.
    public static func reconcileSameIdentityAuthData(
        managedNativeData: Data,
        managedSourceData: Data? = nil,
        expectedIdentity: CodexAccountIdentity,
        candidatePaths: [String],
        fm: FileManager = .default
    ) -> ReconciledAuthPayload {
        guard let nativeSnapshot = parseAuthSnapshot(from: managedNativeData),
              expectedIdentity.matches(nativeSnapshot.identity) else {
            return invalidReconciledPayload()
        }
        if let eKey = expectedIdentity.nativeKey,
           let nKey = nativeSnapshot.identity.nativeKey,
           eKey != nKey {
            return invalidReconciledPayload()
        }

        var managedSnapshot = nativeSnapshot
        if let managedSourceData {
            guard let sourceSnapshot = parseAuthSnapshot(from: managedSourceData),
                  expectedIdentity.matches(sourceSnapshot.identity),
                  nativeSnapshot.identity.matches(sourceSnapshot.identity) else {
                return invalidReconciledPayload()
            }
            if let sKey = sourceSnapshot.identity.nativeKey,
               let nKey = nativeSnapshot.identity.nativeKey,
               sKey != nKey {
                return invalidReconciledPayload()
            }
            if isStrictlyNewer(sourceSnapshot, than: managedSnapshot) {
                managedSnapshot = sourceSnapshot
            }
        }

        var best = managedSnapshot
        var adoptedLive = false

        for path in candidatePaths {
            guard let candData = fm.contents(atPath: path),
                  let candSnapshot = parseAuthSnapshot(from: candData) else {
                continue
            }
            guard expectedIdentity.matches(candSnapshot.identity),
                  managedSnapshot.identity.matches(candSnapshot.identity) else {
                continue
            }
            if let mKey = managedSnapshot.identity.nativeKey,
               let cKey = candSnapshot.identity.nativeKey,
               mKey != cKey {
                continue
            }
            if isStrictlyNewer(candSnapshot, than: best) {
                best = candSnapshot
                adoptedLive = true
            }
        }

        let (bestNativeData, bestNativeJSON) = buildCleanNativePayload(from: best)
        let emittedIdentity = CodexAccountIdentity(authJSON: bestNativeJSON)
        let tokensOnlyIdentity = CodexAccountIdentity(
            authJSON: ["tokens": (bestNativeJSON["tokens"] as? [String: Any]) ?? [:]]
        )
        guard emittedIdentity.accountId != nil,
              tokensOnlyIdentity.accountId != nil,
              let verifiedEmittedSnapshot = parseAuthSnapshot(from: bestNativeData),
              expectedIdentity.matches(emittedIdentity),
              expectedIdentity.matches(tokensOnlyIdentity),
              managedSnapshot.identity.matches(emittedIdentity),
              best.identity.matches(emittedIdentity),
              expectedIdentity.matches(verifiedEmittedSnapshot.identity) else {
            return invalidReconciledPayload()
        }

        let healedManaged: Data? = adoptedLive
            ? buildHealedManagedData(from: managedSourceData ?? managedNativeData, adopting: best)
            : nil
        return ReconciledAuthPayload(
            nativeData: bestNativeData,
            nativeJSON: bestNativeJSON,
            identity: emittedIdentity,
            adoptedLiveCandidate: adoptedLive,
            healedManagedData: healedManaged,
            isValidBaseline: true
        )
    }

    public static func identitiesMatchExactly(_ lhs: CodexAccountIdentity, _ rhs: CodexAccountIdentity) -> Bool {
        guard lhs.matches(rhs) else { return false }
        if let lKey = lhs.nativeKey, let rKey = rhs.nativeKey {
            return lKey == rKey
        }
        return true
    }

    /// Flushes any fresher live Codex OAuth session from `candidatePaths` (e.g. `~/.codex/auth.json` and `.bak`)
    /// back into managed credential files and their linked CPA copies BEFORE an incoming account switch
    /// overwrites the shared live auth file.
    @discardableResult
    public static func flushLiveAuthToManagedCopies(
        candidatePaths: [String],
        excludingIdentity: CodexAccountIdentity,
        loadCredentials: () -> [AccountCredential],
        fm: FileManager = .default
    ) -> Int {
        let normalizedCandidates = candidatePaths.map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path
        }
        let candidateSet = Set(normalizedCandidates)
        let hasOutgoingCandidate = normalizedCandidates.contains { path in
            guard let data = fm.contents(atPath: path),
                  let snapshot = parseAuthSnapshot(from: data) else {
                return false
            }
            return !identitiesMatchExactly(excludingIdentity, snapshot.identity)
        }
        guard hasOutgoingCandidate else { return 0 }

        var writtenCount = 0
        var visitedPaths = Set<String>()

        for credential in loadCredentials() where credential.providerId == "codex" && credential.authMethod == .authFile {
            let primaryPath = NSString(string: credential.credential).expandingTildeInPath
            let normalizedPrimary = URL(fileURLWithPath: primaryPath).standardizedFileURL.path
            guard !normalizedPrimary.isEmpty,
                  !candidateSet.contains(normalizedPrimary),
                  let primaryData = fm.contents(atPath: primaryPath),
                  let primarySnapshot = parseAuthSnapshot(from: primaryData) else {
                continue
            }

            let credentialIdentity = CodexAccountIdentity(credential: credential)
            let expectedIdentity: CodexAccountIdentity
            if credentialIdentity.key != nil {
                guard identitiesMatchExactly(credentialIdentity, primarySnapshot.identity) else { continue }
                expectedIdentity = primarySnapshot.identity.nativeKey != nil ? primarySnapshot.identity : credentialIdentity
            } else {
                expectedIdentity = primarySnapshot.identity
            }

            guard !identitiesMatchExactly(excludingIdentity, expectedIdentity) else { continue }

            let linkedPaths = CodexLinkedCredentialCopies.paths(
                forCredentialId: credential.id,
                nativeIdentityKey: expectedIdentity.nativeKey
            )
            let targetGroups: [(path: String, sources: [String])] =
                [(primaryPath, normalizedCandidates)]
                + linkedPaths.map { ($0, normalizedCandidates + [primaryPath]) }

            for entry in targetGroups {
                let targetStdPath = URL(fileURLWithPath: NSString(string: entry.path).expandingTildeInPath).standardizedFileURL.path
                guard !targetStdPath.isEmpty,
                      !candidateSet.contains(targetStdPath),
                      visitedPaths.insert(targetStdPath).inserted,
                      let currentData = fm.contents(atPath: entry.path),
                      let targetSnapshot = parseAuthSnapshot(from: currentData),
                      identitiesMatchExactly(expectedIdentity, targetSnapshot.identity) else {
                    continue
                }

                let reconciled = reconcileSameIdentityAuthData(
                    managedNativeData: currentData,
                    managedSourceData: currentData,
                    expectedIdentity: expectedIdentity,
                    candidatePaths: entry.sources,
                    fm: fm
                )
                guard reconciled.isValidBaseline,
                      reconciled.adoptedLiveCandidate,
                      let healedData = reconciled.healedManagedData,
                      healedData != currentData,
                      fm.contents(atPath: entry.path) == currentData else {
                    continue
                }
                do {
                    try healedData.write(to: URL(fileURLWithPath: entry.path), options: .atomic)
                    writtenCount += 1
                } catch {
                    continue
                }
            }
        }
        return writtenCount
    }

    private static func isStrictlyNewer(_ candidate: ParsedAuthSnapshot, than baseline: ParsedAuthSnapshot) -> Bool {
        if baseline.refreshToken != nil && candidate.refreshToken == nil {
            return false
        }
        if candidate.accessIssuedAt > 0 || baseline.accessIssuedAt > 0,
           candidate.accessIssuedAt != baseline.accessIssuedAt {
            return candidate.accessIssuedAt > baseline.accessIssuedAt
        }
        if let candLR = candidate.lastRefreshTime, let baseLR = baseline.lastRefreshTime {
            if candLR != baseLR { return candLR > baseLR }
        } else if candidate.lastRefreshTime != nil && baseline.lastRefreshTime == nil {
            return true
        } else if candidate.lastRefreshTime == nil && baseline.lastRefreshTime != nil {
            return false
        }
        if let candExp = candidate.expiredTime, let baseExp = baseline.expiredTime, candExp != baseExp {
            return candExp > baseExp
        }
        return false
    }

    private static func validateTokenGroup(
        container: [String: Any],
        root: [String: Any],
        isFlat: Bool,
        hasOtherGroup: Bool
    ) -> ValidatedTokenGroup? {
        let snakeAccess = nonEmptyString(container["access_token"])
        let camelAccess = nonEmptyString(container["accessToken"])
        if let s = snakeAccess, let c = camelAccess, s != c { return nil }
        if container["access_token"] is String && snakeAccess == nil && camelAccess != nil { return nil }
        guard let accessToken = snakeAccess ?? camelAccess else { return nil }

        let snakeRefresh = nonEmptyString(container["refresh_token"])
        let camelRefresh = nonEmptyString(container["refreshToken"])
        if let s = snakeRefresh, let c = camelRefresh, s != c { return nil }
        let refreshToken = snakeRefresh ?? camelRefresh

        let snakeId = nonEmptyString(container["id_token"])
        let camelId = nonEmptyString(container["idToken"])
        if let s = snakeId, let c = camelId, s != c { return nil }
        if container["id_token"] is String && snakeId == nil && camelId != nil { return nil }
        let idToken = snakeId ?? camelId

        let pair = CodexAccountIdentity.tokenPairIdentities(accessToken, idToken)
        if idToken != nil && pair.access.conflicts(with: pair.id) {
            return nil
        }

        let containerAcct = nonEmptyString(container["account_id"])
            ?? nonEmptyString(container["accountId"])
            ?? nonEmptyString(container["chatgpt_account_id"])
        let rootAcct = nonEmptyString(root["account_id"])
            ?? nonEmptyString(root["accountId"])
            ?? nonEmptyString(root["chatgpt_account_id"])
        if let cAcct = containerAcct, let rAcct = rootAcct, cAcct.lowercased() != rAcct.lowercased() {
            return nil
        }

        var isolatedTokens: [String: Any] = ["access_token": accessToken]
        if let refreshToken { isolatedTokens["refresh_token"] = refreshToken }
        if let idToken { isolatedTokens["id_token"] = idToken }
        if let acct = containerAcct ?? rootAcct {
            isolatedTokens["account_id"] = acct
        }
        var isolatedJSON: [String: Any] = [
            "auth_mode": (root["auth_mode"] as? String) ?? "chatgpt",
            "tokens": isolatedTokens
        ]
        if !hasOtherGroup {
            if let rootUser = nonEmptyString(root["chatgpt_user_id"]) ?? nonEmptyString(root["user_id"]) {
                isolatedJSON["chatgpt_user_id"] = rootUser
            }
            if let rootEmail = nonEmptyString(root["email"]) {
                isolatedJSON["email"] = rootEmail
            }
        }

        let groupIdentity = CodexAccountIdentity(authJSON: isolatedJSON)
        guard let resolvedAccountId = groupIdentity.accountId,
              groupIdentity.key != nil else {
            return nil
        }

        if let cAcct = containerAcct, cAcct.lowercased() != resolvedAccountId.lowercased() {
            return nil
        }
        if let rAcct = rootAcct, rAcct.lowercased() != resolvedAccountId.lowercased() {
            return nil
        }

        let explicitContainerIdentity = CodexAccountIdentity(
            accountId: containerAcct,
            userId: nonEmptyString(container["chatgpt_user_id"]) ?? nonEmptyString(container["user_id"]),
            email: nonEmptyString(container["email"])
        )
        let explicitRootIdentity = CodexAccountIdentity(
            accountId: rootAcct,
            userId: nonEmptyString(root["chatgpt_user_id"]) ?? nonEmptyString(root["user_id"]),
            email: nonEmptyString(root["email"])
        )
        if groupIdentity.conflicts(with: explicitContainerIdentity)
            || groupIdentity.conflicts(with: explicitRootIdentity)
            || pair.access.conflicts(with: groupIdentity)
            || pair.id.conflicts(with: groupIdentity) {
            return nil
        }

        if let idToken {
            let fullId = CodexAccountIdentity.tokenIdentity(idToken, includeSubjectFallback: true)
            let idHasIdentity = fullId.accountId != nil || fullId.userId != nil || fullId.email != nil
            guard idHasIdentity else { return nil }
        }

        let lastRefreshRaw: String? = isFlat
            ? (nonEmptyString(root["flat_last_refresh"]) ?? nonEmptyString(root["last_refresh"]))
            : (nonEmptyString(container["last_refresh"]) ?? nonEmptyString(root["last_refresh"]))
        let lastRefreshTime = lastRefreshRaw.flatMap(SharedFormatters.parseISO8601)?.timeIntervalSince1970
        let expiredRaw: String? = isFlat
            ? nonEmptyString(root["expired"])
            : (nonEmptyString(container["expired"]) ?? nonEmptyString(root["expired"]))
        let expiredTime = expiredRaw.flatMap(SharedFormatters.parseISO8601)?.timeIntervalSince1970
        let accessIssued = jwtIssuedAt(accessToken)
        let accessIssuedAt = accessIssued > 0 ? accessIssued : jwtIssuedAt(idToken)
        let email = nonEmptyString(container["email"]) ?? nonEmptyString(root["email"]) ?? groupIdentity.email

        return ValidatedTokenGroup(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountId: resolvedAccountId,
            email: email,
            identity: groupIdentity,
            lastRefreshRaw: lastRefreshRaw,
            lastRefreshTime: lastRefreshTime,
            expiredRaw: expiredRaw,
            expiredTime: expiredTime,
            accessIssuedAt: accessIssuedAt
        )
    }

    private static func parseAuthSnapshot(from data: Data) -> ParsedAuthSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if nonEmptyString(json["OPENAI_API_KEY"]) != nil,
           json["tokens"] == nil,
           nonEmptyString(json["access_token"]) == nil,
           nonEmptyString(json["accessToken"]) == nil {
            return nil
        }

        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let hasFlat = nonEmptyString(json["access_token"]) != nil
            || nonEmptyString(json["accessToken"]) != nil
            || nonEmptyString(json["id_token"]) != nil
            || nonEmptyString(json["idToken"]) != nil
        let hasNested = nonEmptyString(tokens["access_token"]) != nil
            || nonEmptyString(tokens["accessToken"]) != nil
            || nonEmptyString(tokens["id_token"]) != nil
            || nonEmptyString(tokens["idToken"]) != nil
        guard hasFlat || hasNested else { return nil }

        let selectedGroup: ValidatedTokenGroup
        if hasFlat && hasNested {
            guard let flatGroup = validateTokenGroup(container: json, root: json, isFlat: true, hasOtherGroup: true),
                  let nestedGroup = validateTokenGroup(container: tokens, root: json, isFlat: false, hasOtherGroup: true),
                  !flatGroup.identity.conflicts(with: nestedGroup.identity),
                  flatGroup.identity.matches(nestedGroup.identity) else {
                return nil
            }
            if let fKey = flatGroup.identity.nativeKey,
               let nKey = nestedGroup.identity.nativeKey,
               fKey != nKey {
                return nil
            }
            let preferFlat: Bool
            if flatGroup.accessIssuedAt != nestedGroup.accessIssuedAt {
                preferFlat = flatGroup.accessIssuedAt > nestedGroup.accessIssuedAt
            } else if let fLR = flatGroup.lastRefreshTime, let nLR = nestedGroup.lastRefreshTime, fLR != nLR {
                preferFlat = fLR > nLR
            } else {
                preferFlat = true
            }
            selectedGroup = preferFlat ? flatGroup : nestedGroup
        } else if hasFlat {
            guard let flatGroup = validateTokenGroup(container: json, root: json, isFlat: true, hasOtherGroup: false) else {
                return nil
            }
            selectedGroup = flatGroup
        } else {
            guard let nestedGroup = validateTokenGroup(container: tokens, root: json, isFlat: false, hasOtherGroup: false) else {
                return nil
            }
            selectedGroup = nestedGroup
        }

        let aggregateIdentity = CodexAccountIdentity(authJSON: json)
        guard aggregateIdentity.accountId != nil,
              !selectedGroup.identity.conflicts(with: aggregateIdentity),
              selectedGroup.identity.matches(aggregateIdentity) else {
            return nil
        }

        let hasCamelNested = tokens["accessToken"] != nil
            || tokens["refreshToken"] != nil
            || tokens["idToken"] != nil
            || tokens["accountId"] != nil
        let isAlreadyCleanNative = (json["tokens"] is [String: Any])
            && (json["auth_mode"] != nil)
            && !hasFlat
            && !hasCamelNested

        return ParsedAuthSnapshot(
            rawData: data,
            rawJSON: json,
            identity: selectedGroup.identity,
            accessToken: selectedGroup.accessToken,
            refreshToken: selectedGroup.refreshToken,
            idToken: selectedGroup.idToken,
            accountId: selectedGroup.accountId,
            email: selectedGroup.email,
            lastRefreshRaw: selectedGroup.lastRefreshRaw,
            lastRefreshTime: selectedGroup.lastRefreshTime,
            expiredRaw: selectedGroup.expiredRaw,
            expiredTime: selectedGroup.expiredTime,
            accessIssuedAt: selectedGroup.accessIssuedAt,
            isAlreadyCleanNative: isAlreadyCleanNative
        )
    }

    private static func buildCleanNativePayload(from snapshot: ParsedAuthSnapshot) -> (Data, [String: Any]) {
        if snapshot.isAlreadyCleanNative {
            return (snapshot.rawData, snapshot.rawJSON)
        }
        var native: [String: Any] = [
            "auth_mode": (snapshot.rawJSON["auth_mode"] as? String) ?? "chatgpt",
            "tokens": [
                "access_token": snapshot.accessToken,
                "refresh_token": snapshot.refreshToken ?? "",
                "account_id": snapshot.accountId ?? "",
                "id_token": snapshot.idToken ?? ""
            ] as [String: Any],
            "last_refresh": snapshot.lastRefreshRaw ?? SharedFormatters.iso8601String(from: Date())
        ]
        if let email = snapshot.email, !email.isEmpty {
            native["email"] = email
        }
        native["OPENAI_API_KEY"] = NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])) ?? snapshot.rawData
        return (data, native)
    }

    private static func buildHealedManagedData(from originalData: Data, adopting best: ParsedAuthSnapshot) -> Data? {
        guard var json = (try? JSONSerialization.jsonObject(with: originalData)) as? [String: Any] else {
            return nil
        }
        let hadNested = json["tokens"] is [String: Any]
        if var tokens = json["tokens"] as? [String: Any] {
            tokens["access_token"] = best.accessToken
            tokens.removeValue(forKey: "accessToken")
            if let rt = best.refreshToken { tokens["refresh_token"] = rt }
            tokens.removeValue(forKey: "refreshToken")
            if let it = best.idToken {
                tokens["id_token"] = it
            } else {
                tokens.removeValue(forKey: "id_token")
            }
            tokens.removeValue(forKey: "idToken")
            if let acct = best.accountId { tokens["account_id"] = acct }
            tokens.removeValue(forKey: "accountId")
            tokens.removeValue(forKey: "last_refresh")
            json["tokens"] = tokens
        }
        let hasFlatTokens = !hadNested
            || json["access_token"] != nil
            || json["accessToken"] != nil
            || json["id_token"] != nil
            || json["idToken"] != nil
        if hasFlatTokens {
            json["access_token"] = best.accessToken
            json.removeValue(forKey: "accessToken")
            if let rt = best.refreshToken { json["refresh_token"] = rt }
            json.removeValue(forKey: "refreshToken")
            if let it = best.idToken {
                json["id_token"] = it
            } else {
                json.removeValue(forKey: "id_token")
            }
            json.removeValue(forKey: "idToken")
            if let acct = best.accountId, json["account_id"] != nil || json["accountId"] != nil {
                json["account_id"] = acct
                json.removeValue(forKey: "accountId")
            }
        }
        json.removeValue(forKey: "flat_last_refresh")
        if let lr = best.lastRefreshRaw {
            json["last_refresh"] = lr
        }
        if json["expired"] != nil {
            let jwtExp = (CodexAccountIdentity.jwtPayload(best.accessToken)?["exp"] as? NSNumber)?.doubleValue
            let validBestExpired: String? = {
                guard let expRaw = best.expiredRaw else { return nil }
                if let expTime = best.expiredTime, expTime <= Date().timeIntervalSince1970 + 300,
                   let jwtExp, jwtExp > expTime {
                    return nil
                }
                return expRaw
            }()
            if let exp = validBestExpired {
                json["expired"] = exp
            } else if let jwtExp {
                json["expired"] = SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: jwtExp))
            } else {
                json.removeValue(forKey: "expired")
            }
        }
        guard let healedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let healedSnapshot = parseAuthSnapshot(from: healedData),
              healedSnapshot.identity.matches(best.identity),
              CodexAccountIdentity(authJSON: json).matches(best.identity) else {
            return nil
        }
        return healedData
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtIssuedAt(_ token: String?) -> Double {
        guard let pieces = token?.split(separator: "."), pieces.count >= 2 else { return 0 }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        if let iat = (json["iat"] as? NSNumber)?.doubleValue { return iat }
        if let exp = (json["exp"] as? NSNumber)?.doubleValue { return exp }
        return 0
    }

    static func belongsToSameWorkspace(
        lhsAccountID: String?,
        lhsUserID: String?,
        rhsAccountID: String?,
        rhsUserID: String?
    ) -> Bool {
        let lhs = CodexAccountIdentity(accountId: lhsAccountID, userId: lhsUserID)
        let rhs = CodexAccountIdentity(accountId: rhsAccountID, userId: rhsUserID)
        return lhs.nativeKey != nil && lhs.nativeKey == rhs.nativeKey
    }

    static func refreshFailure(statusCode: Int, data: Data) -> ProviderError {
        let details = oauthErrorDetails(from: data)
        let code = normalized(details.code)?.replacingOccurrences(of: "-", with: "_")
        let description = normalized(details.description) ?? ""
        let combined = [code, description].compactMap { $0 }.joined(separator: " ")

        if combined.contains("reused")
            || combined.contains("already used")
            || combined.contains("rotat") {
            return ProviderError(
                "refresh_token_reused",
                "The Codex refresh token was already rotated by another session. Sign in again to replace this credential."
            )
        }

        if combined.contains("expired") || combined.contains("revoked") {
            return ProviderError(
                "refresh_token_expired",
                "The Codex refresh token expired or was revoked. Sign in again to reconnect this account."
            )
        }

        if code == "invalid_grant"
            || code == "invalid_token"
            || statusCode == 400
            || statusCode == 401 {
            return ProviderError(
                "refresh_token_invalid",
                "The Codex refresh token was rejected. Sign in again if the account does not recover automatically."
            )
        }

        if statusCode == 429 {
            return ProviderError(
                "oauth_rate_limited",
                "Codex OAuth is temporarily rate limited. Wait a moment and try again."
            )
        }

        if (500..<600).contains(statusCode) {
            return ProviderError(
                "oauth_server_error",
                "Codex OAuth is temporarily unavailable (HTTP \(statusCode))."
            )
        }

        return ProviderError(
            "oauth_refresh_failed",
            "Codex OAuth refresh failed (HTTP \(statusCode))."
        )
    }

    static func refreshTransportFailure(_ error: Error) -> ProviderError {
        guard let urlError = error as? URLError else {
            return ProviderError(
                "oauth_network_error",
                "Codex OAuth refresh could not complete because of a network error."
            )
        }

        switch urlError.code {
        case .timedOut:
            return ProviderError(
                "oauth_network_timeout",
                "Codex OAuth refresh timed out. Check the network or proxy and try again."
            )
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed:
            return ProviderError(
                "oauth_network_unavailable",
                "Codex OAuth could not reach the authentication service. Check the network or proxy."
            )
        default:
            return ProviderError(
                "oauth_network_error",
                "Codex OAuth refresh failed because of a network error."
            )
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func oauthErrorDetails(from data: Data) -> (code: String?, description: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }

        if let code = object["error"] as? String {
            return (code, object["error_description"] as? String ?? object["message"] as? String)
        }
        if let nested = object["error"] as? [String: Any] {
            return (
                nested["code"] as? String ?? nested["type"] as? String,
                nested["message"] as? String ?? object["error_description"] as? String
            )
        }
        return (nil, object["error_description"] as? String ?? object["message"] as? String)
    }
}
