#!/bin/sh
# Builds utmwatch-net for macOS arm64 and linux amd64 into Net/bin/.
# Needs the Go toolchain (see go.mod for the minimum version). No cgo.
set -eu
cd "$(dirname "$0")"

# Drop Tailscale features the helper never uses; this is what keeps it small.
TAGS="ts_omit_aws,ts_omit_bird,ts_omit_tap,ts_omit_kube,ts_omit_completion,ts_omit_ssh,ts_omit_wakeonlan,ts_omit_capture,ts_omit_relayserver,ts_omit_taildrop,ts_omit_tpm,ts_omit_webclient,ts_omit_drive,ts_omit_systray,ts_omit_desktop_sessions,ts_omit_syspolicy"
LDFLAGS="-s -w"

mkdir -p bin
build() {
  out="bin/utmwatch-net-$1-$2"
  CGO_ENABLED=0 GOOS="$1" GOARCH="$2" go build -trimpath -tags "$TAGS" -ldflags "$LDFLAGS" -o "$out" .
  printf '%s  %s bytes\n' "$out" "$(wc -c < "$out" | tr -d ' ')"
}
build darwin arm64
build linux amd64
