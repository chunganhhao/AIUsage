#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${AIUSAGE_RESET_SWIFTPM_SCRATCH:-${TMPDIR:-/tmp}/aiusage-reset-cards-swiftpm}"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-reset-regression.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT
swift build --build-system native --package-path "$PROJECT_DIR/QuotaBackend" --scratch-path "$SCRATCH" --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build --build-system native --package-path "$PROJECT_DIR/QuotaBackend" --scratch-path "$SCRATCH" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BACKEND_BIN/description.json" > "$REGRESSION_DIR/backend-objects.txt"
# 编译正式转换/定向刷新方法，系统边界由 fixture engine 替换。
ruby - "$PROJECT_DIR" "$REGRESSION_DIR/ProductionRefreshMethods.swift" <<'RUBY'
root, output = ARGV
def extract(source, name)
  pattern = /^    (?:nonisolated )?func #{Regexp.escape(name)}\(/
  lines = source.lines
  start = lines.index { |line| line.match?(pattern) }
  abort "Missing method: #{name}" unless start
  finish = ((start + 1)...lines.size).find { |i| lines[i].match?(/^    }\s*$/) }
  abort "Missing terminator: #{name}" unless finish
  lines[start..finish].join
end
conversion = File.read(File.join(root, 'AIUsage/ViewModels/ProviderRefreshCoordinator+Conversion.swift'))
pipeline = File.read(File.join(root, 'AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift'))
coordinator = File.read(File.join(root, 'AIUsage/ViewModels/ProviderRefreshCoordinator.swift'))
methods = %w[convertSummary convertOverview localizeProviderData localizeOverview localizedCostPeriod localizedTimelinePoint localizedProviderResults localizedDashboard localizedProviderList localizedRemoteDashboard].map { |name| extract(conversion, name) }
methods += %w[codexResetIdentity preserveCodexResetUpdates fetchAccountByCredential fetchSingleProviderLocal fetchSingleProviderRemote fetchDashboardLocal fetchDashboardRemote replaceProviderEntries].map { |name| extract(pipeline, name) }
methods += [extract(pipeline, 'reconcileResetProtectedAccountRegistry')] if pipeline.include?('func reconcileResetProtectedAccountRegistry(')
methods += [extract(coordinator, 'refreshCodexAccountAfterReset')]
File.write(output, "import Foundation\nimport QuotaBackend\nextension ProviderRefreshCoordinator {\n" + methods.join("\n") + "}\n")
# 保留正式 worker 算法，只在返回前加确定性的挂起点，测试真实 AccountStore 的提交边界。
persistence = File.read(File.join(root, 'AIUsage/Models/AccountStore+Persistence.swift'))
persistence.sub!(') -> AccountRegistryReconcileResult {', ') async -> AccountRegistryReconcileResult {')
abort 'Missing worker suspension seam' unless persistence.sub!('        return AccountRegistryReconcileResult(accounts: snapshot.accountRegistry,', "        await FixtureRegistryGate.shared.pause(providers)\n        return AccountRegistryReconcileResult(accounts: snapshot.accountRegistry,")
File.write(File.join(File.dirname(output), 'GatedAccountPersistence.swift'), persistence)
RUBY
MAIN_SOURCE="$PROJECT_DIR/scripts/CodexResetCardsRegression.swift"
UI_SOURCES=(
  "$PROJECT_DIR/AIUsage/Views/AppSurfaceTokens.swift"
  "$PROJECT_DIR/AIUsage/Views/GatewayChrome.swift"
  "$PROJECT_DIR/AIUsage/Views/CodexResetCreditsView.swift"
)
SUPPORT_SOURCES=(
  "$PROJECT_DIR/AIUsage/Models/AccountStore.swift"
  "$REGRESSION_DIR/GatedAccountPersistence.swift"
  "$PROJECT_DIR/AIUsage/Models/AccountStore+Matching.swift"
  "$PROJECT_DIR/AIUsage/Services/ProviderAuth/ProviderAuthTypes.swift"
  "$PROJECT_DIR/AIUsage/Services/ProviderAuth/ProviderAuthParsing.swift"
  "$PROJECT_DIR/scripts/AccountIdentityRegressionSupport.swift"
  "$PROJECT_DIR/AIUsage/ViewModels/ProviderRefreshResult.swift"
  "$PROJECT_DIR/AIUsage/ViewModels/CodexResetRefreshFence.swift"
  "$PROJECT_DIR/scripts/CodexResetCoordinatorSupport.swift"
  "$REGRESSION_DIR/ProductionRefreshMethods.swift"
)
STUB_SOURCE="$PROJECT_DIR/QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift"
COORDINATOR_SOURCE="$PROJECT_DIR/AIUsage/ViewModels/CodexResetCreditsCoordinator.swift"
if [[ "${1:-}" == "--render" ]]; then
  MAIN_SOURCE="$PROJECT_DIR/scripts/CodexResetCardsRenderer.swift"
  shift
  # 只替换 shared 绑定为显式 fixture coordinator；不实例化生产 singleton。
  # 时间视图使用正式实现，但去掉全局轮询时钟；#Preview 宏不参与独立 swiftc。
  ruby - "$PROJECT_DIR" "$REGRESSION_DIR" <<'RUBY'
root, output = ARGV
coordinator = File.read(File.join(root, 'AIUsage/ViewModels/CodexResetCreditsCoordinator.swift'))
abort 'Missing coordinator shared binding' unless coordinator.sub!('static let shared = CodexResetCreditsCoordinator()', 'static var shared: CodexResetCreditsCoordinator { FixtureResetEnvironment.coordinator }')
File.write(File.join(output, 'PreviewResetCoordinator.swift'), coordinator)
card = File.read(File.join(root, 'AIUsage/Views/ProviderCard.swift')).split(/^#Preview \{/).first
File.write(File.join(output, 'PreviewProviderCard.swift'), card)
utilities = File.read(File.join(root, 'AIUsage/Views/Utilities.swift')).split('// MARK: - Refreshable Time Views', 2).last
File.write(File.join(output, 'PreviewUtilities.swift'), "import SwiftUI\nimport Combine\nimport QuotaBackend\n" + utilities)
# 渲染时拦截所有 HTTP(S)，意外 POST 在发送前直接失败。
stub = File.read(File.join(root, 'QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift'))
abort 'Missing URL interception boundary' unless stub.sub!(/    override class func canInit\(with request: URLRequest\) -> Bool \{.*?^    }/m, '    override class func canInit(with request: URLRequest) -> Bool { ["http", "https"].contains(request.url?.scheme ?? "") }')
abort 'Missing request boundary' unless stub.sub!('        guard let url = request.url else { return }', '        precondition(request.httpMethod == nil || request.httpMethod == "GET", "Preview only permits GET fixtures")' + "\n" + '        guard let url = request.url else { return }')
File.write(File.join(output, 'PreviewStubURLProtocol.swift'), stub)
RUBY
  COORDINATOR_SOURCE="$REGRESSION_DIR/PreviewResetCoordinator.swift"
  SUPPORT_SOURCES=("$PROJECT_DIR/scripts/ProviderCardResetPreviewSupport.swift")
  STUB_SOURCE="$REGRESSION_DIR/PreviewStubURLProtocol.swift"
  UI_SOURCES+=(
    "$REGRESSION_DIR/PreviewProviderCard.swift"
    "$REGRESSION_DIR/PreviewUtilities.swift"
    "$PROJECT_DIR/AIUsage/Views/ProviderIconView.swift"
    "$PROJECT_DIR/AIUsage/Views/ProviderCard+MultiWindowQuota.swift"
    "$PROJECT_DIR/AIUsage/Views/ProviderCard+QuotaIndicator.swift"
    "$PROJECT_DIR/AIUsage/Views/SmallProgressView.swift"
    "$PROJECT_DIR/AIUsage/Views/MenuBarAccountRow.swift"
    "$PROJECT_DIR/AIUsage/Views/MenuBarRows.swift"
    "$PROJECT_DIR/AIUsage/Views/MenuBarSupport.swift"
  )
fi
swiftc -parse-as-library -swift-version 5 \
  -I "$BACKEND_BIN/Modules" -Xlinker -filelist -Xlinker "$REGRESSION_DIR/backend-objects.txt" \
  "$PROJECT_DIR/AIUsage/Models/ProviderModels.swift" \
  "${SUPPORT_SOURCES[@]}" \
  "$COORDINATOR_SOURCE" \
  "$STUB_SOURCE" \
  "${UI_SOURCES[@]}" \
  "$MAIN_SOURCE" \
  -o "$REGRESSION_DIR/reset-regression"
"$REGRESSION_DIR/reset-regression" "$@"
