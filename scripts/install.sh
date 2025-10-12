#!/usr/bin/env bash

# Installs the cmtly binary into ${HOME}/.cmtly/bin and reminds you
# to add that directory to your PATH.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="${ROOT_DIR}/cmtly/main.swift"
INSTALL_DIR="${HOME}/.cmtly/bin"
BUILD_CACHE="$(mktemp -d)"

cleanup() {
    rm -rf "${BUILD_CACHE}"
}
trap cleanup EXIT

if [[ ! -f "${SOURCE_FILE}" ]]; then
    echo "💥 Source file not found at ${SOURCE_FILE}" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "💥 xcrun is required to build cmtly. Install Xcode command line tools first." >&2
    exit 1
fi

echo "⚙️  Building cmtly…"
xcrun swiftc "${SOURCE_FILE}" \
    -module-cache-path "${BUILD_CACHE}/ModuleCache" \
    -O \
    -o "${BUILD_CACHE}/cmtly"

mkdir -p "${INSTALL_DIR}"
cp "${BUILD_CACHE}/cmtly" "${INSTALL_DIR}/cmtly"
chmod +x "${INSTALL_DIR}/cmtly"

echo "🎉 cmtly installed to ${INSTALL_DIR}/cmtly"
echo "   Run 'cmtly' from a new shell to generate commit messages."
echo "ℹ️  Ensure ${INSTALL_DIR} is on your PATH before running 'cmtly'."

cat <<'INSTRUCTIONS'

PATH setup examples:
  • zsh:  echo 'export PATH="$HOME/.cmtly/bin:$PATH"' >> ~/.zshrc
  • bash: echo 'export PATH="$HOME/.cmtly/bin:$PATH"' >> ~/.bash_profile
  • fish: set -U fish_user_paths $HOME/.cmtly/bin $fish_user_paths

Restart your terminal or source the shell profile after updating PATH.
INSTRUCTIONS
