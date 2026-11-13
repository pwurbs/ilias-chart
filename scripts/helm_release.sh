#!/bin/bash
# scripts/helm_release.sh
# Packages the Helm chart and pushes it to an OCI-compatible Helm/container registry.
#
# Usage: bash scripts/helm_release.sh
#
# Configuration (env vars, all optional — skips the matching prompt below when set):
#   REGISTRY        OCI registry host
#   REGISTRY_USER   Registry user/organization
#   REGISTRY_PATH   Path under the user/org to push to
#   REGISTRY_TOKEN  Registry token/password with package-write permission; without it, the
#                   token comes from the macOS keychain item `codeberg-push-token`
#
# Prerequisites:
#   - helm 3.8+ installed
#   - Keychain item `codeberg-push-token` (unless REGISTRY_TOKEN is set), created with
#     security add-generic-password -a "$USER" -s codeberg-push-token -T "" -w
#     With -T "" no application is trusted, so every read asks for the keychain password.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/../chart"
DIST_DIR="${SCRIPT_DIR}/../dist"

if [[ -z "${REGISTRY}" ]]; then
    read -rp "OCI registry host (e.g. codeberg.org): " REGISTRY
fi

if [[ -z "${REGISTRY_USER}" ]]; then
    read -rp "Registry user/organization: " REGISTRY_USER
fi

if [[ -z "${REGISTRY_PATH}" ]]; then
    read -rp "Path under the user/org to push to (e.g. charts): " REGISTRY_PATH
fi

if [[ -z "${REGISTRY_TOKEN:-}" ]]; then
    REGISTRY_TOKEN=$(security find-generic-password -a "$USER" -s codeberg-push-token -w 2>/dev/null || true)
fi
if [[ -z "${REGISTRY_TOKEN:-}" ]]; then
    echo "REGISTRY_TOKEN is not set and the keychain item 'codeberg-push-token' could not be read (missing or access denied). Aborting." >&2
    exit 1
fi

OCI_REPO="oci://${REGISTRY}/${REGISTRY_USER}/${REGISTRY_PATH}"

CHART_VERSION=$(awk '/^version:/ {print $2}' "${CHART_DIR}/Chart.yaml")

echo "==> Packaging chart ilias-${CHART_VERSION} ..."
mkdir -p "${DIST_DIR}"
helm package "${CHART_DIR}" -d "${DIST_DIR}"

# helm registry login writes the token to the registry config file: the trap logs out on every
# exit, also after a failed push, so it stays there only while the script runs.
trap 'helm registry logout "${REGISTRY}" >/dev/null 2>&1 || true' EXIT
echo "==> Logging in to ${REGISTRY} as ${REGISTRY_USER} ..."
printf '%s' "${REGISTRY_TOKEN}" | helm registry login "${REGISTRY}" -u "${REGISTRY_USER}" --password-stdin
unset REGISTRY_TOKEN

echo "==> Pushing to ${OCI_REPO} ..."
helm push "${DIST_DIR}/ilias-${CHART_VERSION}.tgz" "${OCI_REPO}"

echo ""
echo "==> Done!"
echo "    Install with: helm install ilias ${OCI_REPO}/ilias --version ${CHART_VERSION}"
