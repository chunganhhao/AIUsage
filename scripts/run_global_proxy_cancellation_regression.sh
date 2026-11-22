#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-proxy-cancel.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT

# 从正式源码提取方法原文，避免为测试搬动生产代码或复制一套实现。
# Swift 顶层类型成员使用四空格缩进；只接受唯一的起止匹配，源码变化时明确失败。
ruby -E UTF-8:UTF-8 - "$PROJECT_DIR" "$REGRESSION_DIR/ProductionMethods.swift" "${1:-}" <<'RUBY'
root, destination, mode = ARGV
def extract(source, start_pattern, end_pattern)
  lines = source.lines
  starts = lines.each_index.select { |index| lines[index].match?(start_pattern) }
  abort "Expected exactly one source match: #{start_pattern}" unless starts.length == 1
  first = starts.first
  last = ((first + 1)...lines.length).find { |index| lines[index].match?(end_pattern) }
  abort "Missing source terminator: #{start_pattern}" unless last
  lines[first..last].join
end

runtime = File.read(File.join(root, 'AIUsage/Services/GlobalProxyRuntime.swift'))
manager = File.read(File.join(root, 'AIUsage/ViewModels/GlobalProxyManager.swift'))
if mode == '--baseline'
  runtime = IO.popen(['git', '-C', root, 'show', 'HEAD:AIUsage/Services/GlobalProxyRuntime.swift'], &:read)
  manager = IO.popen(['git', '-C', root, 'show', 'HEAD:AIUsage/ViewModels/GlobalProxyManager.swift'], &:read)
end
output = "import Foundation\nimport os.log\n"
output += extract(runtime, /^enum GlobalProxyRuntimeError:/, /^}\s*$/)
[
  ['GlobalProxyRuntime', runtime, /^    func switchUpstream\(/],
  ['GlobalProxyManager', manager, /^    func reapplyActiveUpstream\(/]
].each do |type, source, signature|
  method = extract(source, signature, /^    }\s*$/)
  output += "\nextension #{type} {\n#{method}}\n"
end
File.write(destination, output)
RUBY

swiftc -parse-as-library -swift-version 5 \
  "$PROJECT_DIR/scripts/GlobalProxyCancellationRegression.swift" \
  "$REGRESSION_DIR/ProductionMethods.swift" \
  -o "$REGRESSION_DIR/proxy-cancellation-regression"
"$REGRESSION_DIR/proxy-cancellation-regression"
