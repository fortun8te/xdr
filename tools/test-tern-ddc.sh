#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_root="$(dirname -- "$script_dir")"
test_temp_dir="$(mktemp -d -t xdr-ddc-checks)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$test_temp_dir"' EXIT
swiftc -parse-as-library "$project_root/XDR/Services/TernDDCController.swift" "$script_dir/TernDDCRegression.swift" -framework AppKit -framework CoreGraphics -o "$test_temp_dir/checks"
"$test_temp_dir/checks"
