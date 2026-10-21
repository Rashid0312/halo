#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Downloads the pinned sherpa-onnx 1.13.8 libraries into .native and the
# wake/VAD models into models, verifying each file. Skips files already present.
mkdir -p .native models
REL="https://github.com/k2-fsa/sherpa-onnx/releases/download"
KWS="sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
KWS_PART="epoch-12-avg-2-chunk-16-left-64.int8.onnx"

check() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$2" ]; }
verify() { check "$1" "$2" || { printf 'Checksum mismatch: %s\n' "$1" >&2; exit 1; }; }

LIBS=(
    "libsherpa-onnx-c-api.dylib 6baf16572b925c6d4722a3ffdb7d34c3de6477ba6e587baf8c4573cc3f889ca1"
    "libonnxruntime.dylib b0613d0ae53199a83b05fa48e169211498e9d40d54beaa372068ebe5ec5b0929"
)
MODELS=(
    "silero_vad.onnx 9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6"
    "$KWS/encoder-$KWS_PART 1e721676515bcd42a186979733981213c66c80db680e1cc582dfedf3be76e678"
    "$KWS/decoder-$KWS_PART e40ff43297abe815e8898494c17e71bba2152d9d40fa3eb803f75d0f7533329a"
    "$KWS/joiner-$KWS_PART eae9da0c7e1e6c6a3f4cc42d167899c388f6c6701b94cb96320e4f55df79624c"
    "$KWS/tokens.txt fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53"
)

TMP="$(mktemp -d "${TMPDIR:-/tmp}/halo-deps.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

missing() { for row in "$@"; do set -- $row; check "$PREFIX/$1" "$2" || return 0; done; return 1; }

PREFIX=.native
if missing "${LIBS[@]}"; then
    printf 'Downloading sherpa-onnx 1.13.8 libraries…\n'
    # The npm package carries the exact prebuilt macOS arm64 libraries; no Node is needed.
    curl -fsSL https://registry.npmjs.org/sherpa-onnx-darwin-arm64/-/sherpa-onnx-darwin-arm64-1.13.8.tgz | tar xz -C "$TMP"
    for row in "${LIBS[@]}"; do set -- $row; cp "$TMP/package/$1" .native/; done
fi
for row in "${LIBS[@]}"; do set -- $row; verify ".native/$1" "$2"; done

PREFIX=models
if ! check models/silero_vad.onnx 9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6; then
    printf 'Downloading Silero VAD…\n'
    curl -fsSL "$REL/asr-models/silero_vad.onnx" -o models/silero_vad.onnx
fi
if missing "${MODELS[@]:1}"; then
    printf 'Downloading %s…\n' "$KWS"
    curl -fsSL "$REL/kws-models/$KWS.tar.bz2" | tar xj -C models "$KWS/encoder-$KWS_PART" "$KWS/decoder-$KWS_PART" "$KWS/joiner-$KWS_PART" "$KWS/tokens.txt"
fi
for row in "${MODELS[@]}"; do set -- $row; verify "models/$1" "$2"; done
printf 'Dependencies ready.\n'
