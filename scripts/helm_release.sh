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
#   REGISTRY_TOKEN  Registry token/password with package-write permission
#
# Prerequisites:
#   - helm 3.8+ installed

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

if [[ -z "${REGISTRY_TOKEN}" ]]; then
    read -rsp "Token for ${REGISTRY_USER}@${REGISTRY} (package write permission): " REGISTRY_TOKEN
    echo
fi

OCI_REPO="oci://${REGISTRY}/${REGISTRY_USER}/${REGISTRY_PATH}"

CHART_VERSION=$(awk '/^version:/ {print $2}' "${CHART_DIR}/Chart.yaml")

echo "==> Logging in to ${REGISTRY} as ${REGISTRY_USER} ..."
echo "${REGISTRY_TOKEN}" | helm registry login "${REGISTRY}" -u "${REGISTRY_USER}" --password-stdin

echo "==> Packaging chart ilias-${CHART_VERSION} ..."
mkdir -p "${DIST_DIR}"
helm package "${CHART_DIR}" -d "${DIST_DIR}"

echo "==> Pushing to ${OCI_REPO} ..."
helm push "${DIST_DIR}/ilias-${CHART_VERSION}.tgz" "${OCI_REPO}"

echo ""
echo "==> Done!"
echo "    Install with: helm install ilias ${OCI_REPO}/ilias --version ${CHART_VERSION}"
