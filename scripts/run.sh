#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/bundle-app.sh" debug
open "$ROOT/Dictate.app"
echo "Dictate is running in the menu bar. Hold Right Option to talk."
