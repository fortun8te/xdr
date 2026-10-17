# Bundled DDC helper

Source: https://github.com/waydabber/m1ddc, MIT licensed. This snapshot is kept in source form so a clone can rebuild its helper rather than depending on a committed executable.

XDR adds reply validation for header, length, opcode, requested feature, result and checksum, bounded retries for transient reads, and explicit unsigned value decoding. An unsupported feature must return an error rather than a plausible stale number. The selected display is identified before hardware access.

Build with `scripts/build-ddc.sh` from the repository root. The generated helper and object files are ignored. This helper's DDC transport is for Apple Silicon Macs.
