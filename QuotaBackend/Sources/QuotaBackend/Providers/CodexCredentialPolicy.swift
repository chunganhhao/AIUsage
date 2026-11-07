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

    private static func jwtPayload(_ token: String?) -> [String: Any]? {
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

enum CodexCredentialPolicy {
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
