#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift test --package-path Packages/VerilogIDECore
Scripts/verify_samples.sh
