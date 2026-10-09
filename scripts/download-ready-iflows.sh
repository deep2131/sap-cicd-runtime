#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "SAP CPI - ReadyForDeployment Downloader"
echo "=================================================="

required_vars=(
  SAP_TOKEN_URL
  SAP_CLIENT_ID
  SAP_CLIENT_SECRET
  SAP_BASE_URL
)

for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "::error::$var is not configured."
    exit 1
  fi
done

API_BASE="${SAP_BASE_URL%/}"
API_BASE="${API_BASE%/api/v1}"

WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
DOWNLOAD_DIR="${WORKSPACE}/artifacts"
TEMP_DIR="/tmp/cpi-download"

VERSION_REGEX='^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?\.ReadyForDeployment$'

mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$TEMP_DIR"

echo
echo "Output directory:"
echo "$DOWNLOAD_DIR"

# ==================================================
# 1. Generate OAuth token
# ==================================================

echo
echo "Generating SAP OAuth token..."

TOKEN_HTTP_CODE=$(curl \
  --silent \
  --show-error \
  --location \
  --request POST \
  --output "${TEMP_DIR}/token.json" \
  --write-out "%{http_code}" \
  --user "${SAP_CLIENT_ID}:${SAP_CLIENT_SECRET}" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "grant_type=client_credentials" \
  "$SAP_TOKEN_URL")

echo "Token HTTP status: $TOKEN_HTTP_CODE"

if [ "$TOKEN_HTTP_CODE" != "200" ]; then
  echo "::error::SAP OAuth token request failed."
  cat "${TEMP_DIR}/token.json" || true
  exit 1
fi

SAP_ACCESS_TOKEN=$(jq -r '.access_token // empty' \
  "${TEMP_DIR}/token.json")

if [ -z "$SAP_ACCESS_TOKEN" ]; then
  echo "::error::SAP OAuth token is empty."
  exit 1
fi

echo "OAuth token generated successfully."

# ==================================================
# 2. Helper for CPI GET requests
# ==================================================

cpi_get() {

  local url="$1"
  local output="$2"

  curl \
    --silent \
    --show-error \
    --location \
    --write-out "%{http_code}" \
    --request GET \
    "$url" \
    --header "Authorization: Bearer ${SAP_ACCESS_TOKEN}" \
    --header "Accept: application/json" \
    --output "$output"
}

# ==================================================
# 3. Get Integration Packages
# ==================================================

echo
echo "Fetching IntegrationPackages..."

PACKAGES_FILE="${TEMP_DIR}/packages.json"

HTTP_CODE=$(cpi_get \
  "${API_BASE}/api/v1/IntegrationPackages?\$format=json" \
  "$PACKAGES_FILE")

echo "IntegrationPackages HTTP status: $HTTP_CODE"

if [ "$HTTP_CODE" != "200" ]; then

  echo "::error::Failed to fetch IntegrationPackages."

  cat "$PACKAGES_FILE" || true

  exit 1
fi

PACKAGE_COUNT=$(jq '.d.results | length' "$PACKAGES_FILE")

echo "Packages discovered: $PACKAGE_COUNT"

# ==================================================
# 4. Discover artifacts package-by-package
# ==================================================

ALL_ARTIFACTS="${TEMP_DIR}/all-artifacts.json"

echo '{"d":{"results":[]}}' > "$ALL_ARTIFACTS"

echo
echo "Discovering package artifacts..."

while IFS= read -r PKG_ID; do

  [ -z "$PKG_ID" ] && continue
  [ "$PKG_ID" = "null" ] && continue

  ODATA_PKG_ID=$(printf '%s' "$PKG_ID" |
    sed "s/'/''/g")

  SAFE_PKG=$(printf '%s' "$PKG_ID" |
    tr -cd '[:alnum:]_.-')

  PKG_FILE="${TEMP_DIR}/pkg-${SAFE_PKG}.json"

  PACKAGE_URL="${API_BASE}/api/v1/IntegrationPackages('${ODATA_PKG_ID}')/IntegrationDesigntimeArtifacts?\$format=json"

  HTTP_CODE=$(cpi_get \
    "$PACKAGE_URL" \
    "$PKG_FILE")

  if [ "$HTTP_CODE" = "200" ]; then

    PKG_ARTIFACT_COUNT=$(jq '.d.results | length' "$PKG_FILE")

    echo "$PKG_ID: $PKG_ARTIFACT_COUNT artifact(s)"

    jq -s \
      '{
        d: {
          results:
            (
              (.[0].d.results // [])
              +
              (.[1].d.results // [])
            )
        }
      }' \
      "$ALL_ARTIFACTS" \
      "$PKG_FILE" \
      > "${TEMP_DIR}/merged.json"

    mv "${TEMP_DIR}/merged.json" "$ALL_ARTIFACTS"

  else

    echo "::warning::Package $PKG_ID skipped. HTTP $HTTP_CODE"

  fi

done < <(jq -r '.d.results[]?.Id' "$PACKAGES_FILE")

TOTAL=$(jq '.d.results | length' "$ALL_ARTIFACTS")

echo
echo "Total artifacts discovered: $TOTAL"

# ==================================================
# 5. Select ReadyForDeployment iFlows
# ==================================================

SELECTED_FILE="${TEMP_DIR}/selected-iflows.json"

jq \
  --arg pattern "$VERSION_REGEX" \
  '
  [
    .d.results[]
    |
    select(
      .Id != null
      and (.Version | type == "string")
      and (.Version | test($pattern))
    )
    |
    {
      id: .Id,
      name: (.Name // .Id),
      packageId: .PackageId,
      savedVersion: .Version
    }
  ]
  ' \
  "$ALL_ARTIFACTS" \
  > "$SELECTED_FILE"

MATCHED=$(jq 'length' "$SELECTED_FILE")

echo
echo "=================================================="
echo "ReadyForDeployment Discovery"
echo "=================================================="
echo "Matching artifacts: $MATCHED"

if [ "$MATCHED" -eq 0 ]; then

  echo
  echo "No artifacts found matching:"
  echo "1.2.3.ReadyForDeployment"
  echo "1.2.3.4.ReadyForDeployment"

  exit 0
fi

echo
echo "Selected artifacts:"

jq -r '
  .[]
  |
  "\(.name) | Id=\(.id) | Package=\(.packageId) | Version=\(.savedVersion)"
' "$SELECTED_FILE"

# ==================================================
# 6. Download selected iFlows
# ==================================================

DOWNLOADED_COUNT=0
FAILED_COUNT=0

while IFS= read -r item; do

  IFLOW_ID=$(echo "$item" | jq -r '.id')
  IFLOW_NAME=$(echo "$item" | jq -r '.name')
  VERSION=$(echo "$item" | jq -r '.savedVersion')
  PACKAGE_ID=$(echo "$item" | jq -r '.packageId')

  SAFE_NAME=$(printf '%s' "$IFLOW_NAME" |
    tr '/' '-')

  TARGET_PATH="${DOWNLOAD_DIR}/${SAFE_NAME}/${VERSION}"

  ZIP_FILE="${TARGET_PATH}/${SAFE_NAME}.zip"

  mkdir -p "$TARGET_PATH"

  ODATA_ID=$(printf '%s' "$IFLOW_ID" |
    sed "s/'/''/g")

  ODATA_VER=$(printf '%s' "$VERSION" |
    sed "s/'/''/g")

  URL="${API_BASE}/api/v1/IntegrationDesigntimeArtifacts(Id='${ODATA_ID}',Version='${ODATA_VER}')/\$value"

  echo
  echo "=================================================="
  echo "Downloading artifact"
  echo "=================================================="
  echo "Name    : $IFLOW_NAME"
  echo "ID      : $IFLOW_ID"
  echo "Package : $PACKAGE_ID"
  echo "Version : $VERSION"

  HTTP_CODE=$(curl \
    --silent \
    --show-error \
    --connect-timeout 10 \
    --max-time 90 \
    --location \
    --write-out "%{http_code}" \
    --request GET \
    "$URL" \
    --header "Authorization: Bearer ${SAP_ACCESS_TOKEN}" \
    --header "Accept: application/zip" \
    --output "$ZIP_FILE")

  echo "Download HTTP status: $HTTP_CODE"

  if [ "$HTTP_CODE" != "200" ]; then

    echo "::error::Download failed for $IFLOW_ID"

    rm -f "$ZIP_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))

    continue
  fi

  if [ ! -s "$ZIP_FILE" ]; then

    echo "::error::Downloaded ZIP is empty for $IFLOW_ID"

    rm -f "$ZIP_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))

    continue
  fi

  echo "Validating ZIP..."

  if ! unzip -tq "$ZIP_FILE" >/dev/null 2>&1; then

    echo "::error::Invalid ZIP downloaded for $IFLOW_ID"

    rm -f "$ZIP_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))

    continue
  fi

  echo "Downloaded successfully:"
  echo "$ZIP_FILE"

  DOWNLOADED_COUNT=$((DOWNLOADED_COUNT + 1))

done < <(jq -c '.[]' "$SELECTED_FILE")

# ==================================================
# 7. Final summary
# ==================================================

echo
echo "=================================================="
echo "DOWNLOAD SUMMARY"
echo "=================================================="

echo "Packages discovered        : $PACKAGE_COUNT"
echo "Artifacts discovered       : $TOTAL"
echo "ReadyForDeployment         : $MATCHED"
echo "Downloaded successfully    : $DOWNLOADED_COUNT"
echo "Failed                     : $FAILED_COUNT"

echo
echo "Downloaded ZIP files:"

find "$DOWNLOAD_DIR" \
  -type f \
  -name '*.zip' \
  -print

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo "::error::$FAILED_COUNT artifact download(s) failed."
  exit 1
fi

if [ "$DOWNLOADED_COUNT" -eq 0 ]; then
  echo "::error::No ReadyForDeployment artifacts were downloaded."
  exit 1
fi

echo
echo "=================================================="
echo "READYFORDEPLOYMENT DOWNLOAD SUCCESSFUL"
echo "=================================================="
