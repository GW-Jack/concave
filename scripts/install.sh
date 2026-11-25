#!/usr/bin/env sh
# Concave one-line installer:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/GW-Jack/concave/main/scripts/install.sh | sh
set -eu

main() {
  REPO="GW-Jack/concave"
  INSTALL_ROOT="${CONCAVE_HOME:-$HOME/.concave}"
  BIN_DIR="${CONCAVE_BIN_DIR:-$HOME/.local/bin}"

  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "${OS}" in
    Darwin)
      case "${ARCH}" in
        arm64|aarch64) TARGET="macos-arm64" ;;
        *) echo "Unsupported macOS architecture: ${ARCH}" >&2; exit 1 ;;
      esac
      ;;
    Linux)
      case "${ARCH}" in
        x86_64|amd64) TARGET="linux-x86_64" ;;
        aarch64|arm64) TARGET="linux-aarch64" ;;
        *) echo "Unsupported Linux architecture: ${ARCH}" >&2; exit 1 ;;
      esac
      ;;
    *)
      echo "Unsupported OS: ${OS}" >&2
      exit 1
      ;;
  esac

  if [ -n "${CONCAVE_VERSION:-}" ]; then
    TAG="${CONCAVE_VERSION}"
  else
    TAG="$(curl --proto '=https' --tlsv1.2 -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "${TAG}" ]; then
      echo "Could not resolve latest release tag from GitHub. Set CONCAVE_VERSION=vX.Y.Z or build from source with 'make host'." >&2
      exit 1
    fi
  fi

  if ! printf '%s\n' "${TAG}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'; then
    echo "Invalid Concave release tag: ${TAG}" >&2
    exit 1
  fi

  ARCHIVE="concave-${TAG}-${TARGET}.tar.gz"
  BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR}"' EXIT INT TERM

  echo "Downloading Concave ${TAG} (${TARGET})..."
  curl --proto '=https' --tlsv1.2 -fsSL "${BASE_URL}/${ARCHIVE}" -o "${TMP_DIR}/${ARCHIVE}"
  curl --proto '=https' --tlsv1.2 -fsSL "${BASE_URL}/SHA256SUMS.txt" -o "${TMP_DIR}/SHA256SUMS.txt"

  MATCH_COUNT="$(awk -v f="${ARCHIVE}" '$2 == f { count++ } END { print count + 0 }' "${TMP_DIR}/SHA256SUMS.txt")"
  if [ "${MATCH_COUNT}" -ne 1 ]; then
    echo "Expected exactly 1 checksum entry for ${ARCHIVE} in SHA256SUMS.txt, found ${MATCH_COUNT}" >&2
    exit 1
  fi
  EXPECTED="$(awk -v f="${ARCHIVE}" '$2 == f { print $1 }' "${TMP_DIR}/SHA256SUMS.txt")"
  if ! printf '%s\n' "${EXPECTED}" | grep -Eq '^[0-9a-fA-F]{64}$'; then
    echo "Invalid SHA-256 digest in SHA256SUMS.txt for ${ARCHIVE}" >&2
    exit 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
  else
    ACTUAL="$(shasum -a 256 "${TMP_DIR}/${ARCHIVE}" | awk '{print $1}')"
  fi

  if [ "${ACTUAL}" != "${EXPECTED}" ]; then
    echo "SHA-256 mismatch for ${ARCHIVE}: expected ${EXPECTED}, got ${ACTUAL}" >&2
    exit 1
  fi

  mkdir -p "${INSTALL_ROOT}" "${BIN_DIR}"
  tar -xzf "${TMP_DIR}/${ARCHIVE}" --no-same-owner --no-same-permissions -C "${TMP_DIR}"
  EXTRACTED="${TMP_DIR}/concave-${TAG}-${TARGET}"

  rm -rf "${INSTALL_ROOT}/platform" "${INSTALL_ROOT}/packages"
  cp -R "${EXTRACTED}/platform" "${INSTALL_ROOT}/platform"
  cp -R "${EXTRACTED}/packages" "${INSTALL_ROOT}/packages"
  cp "${EXTRACTED}/bin/concave" "${BIN_DIR}/concave"
  chmod 0755 "${BIN_DIR}/concave"

  echo ""
  echo "Installed concave ${TAG} to ${BIN_DIR}/concave"
  echo "Platform & SDK installed to ${INSTALL_ROOT}"
  echo ""
  echo "Make sure ${BIN_DIR} is in your PATH, then start a new app:"
  echo "  concave init my-app --template=kanban"
}

main "$@"
