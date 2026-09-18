#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
"$project_root/scripts/build-app.sh" debug
open "$project_root/build/Siniulator.app"
