import Foundation

/// Preserves the `GeminiCredentialBridge` name for non-CPA callers while sharing the single implementation.
typealias GeminiCredentialBridge = CLIProxyGeminiCredentialBridge
