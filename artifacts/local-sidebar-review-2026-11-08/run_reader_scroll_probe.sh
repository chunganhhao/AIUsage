#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-reader-scroll.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
python3 - "$ROOT" "$TEMP" <<'EXTRACT'
from pathlib import Path
import sys
root,temp=map(Path,sys.argv[1:])
source=(root/'AIUsage/Views/SessionReaderView.swift').read_text()
slice=source.split('private struct SessionTranscriptView: View {',1)[1].split('private struct TranscriptItemView: View {',1)[0]
(temp/'Reader.swift').write_text('import SwiftUI\nimport AppKit\nstruct SessionTranscriptView: View {'+slice)
EXTRACT
swiftc -parse-as-library -swift-version 5 "$TEMP/Reader.swift" "$ROOT/artifacts/local-sidebar-review-2026-11-08/ReaderScrollProbe.swift" -o "$TEMP/probe"
"$TEMP/probe"
