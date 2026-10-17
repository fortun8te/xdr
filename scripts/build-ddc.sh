#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
make -C "$task_root/Vendor/m1ddc" CC="$(xcrun -f clang)"
install -m 0755 "$task_root/Vendor/m1ddc/m1ddc" "$task_root/XDR/Resources/m1ddc"
install -m 0644 "$task_root/Vendor/m1ddc/LICENSE" "$task_root/XDR/Resources/m1ddc-LICENSE"
