#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "SAP CPI - ReadyForDeployment Artifact Downloader"
echo "=================================================="

# --------------------------------------------------
# 1. Validate required environment variables
# --------------------------------------------------

required_vars=(
  SAP_TOKEN_URL
  SAP_CLIENT_ID
  SAP_CLIENT_SECRET
  SAP_BASE_URL
)

missing=0

for var in "${required_vars[@]}"; do
  if [ -z "${!var:-}" ]; then
    echo "::error::$var is not configured."
    missing=1
  else
    echo "$var is configured."
  fi
done

if [ "$missing" -ne 0 ]; then
  echo "::error::Required SAP configuration is missing."
  exit 1
fi

echo
echo "Required configuration is available."

# --------------------------------------------------
# 2. Normalize SAP base URL
# --------------------------------------------------

BASE_URL="${SAP_BASE_URL%/}"

# Remove API paths if accidentally included in secret
BASE_URL="${BASE_URL%/api/v1/IntegrationDesigntimeArtifacts}"
BASE_URL="${BASE_URL%/api/v1}"

echo
echo "SAP base host:"
echo "$BASE_URL"

# --------------------------------------------------
# 3. Generate OAuth token
# --------------------------------------------------

echo
echo "Generating SAP OAuth token..."

TOKEN_HTTP_CODE=$(curl \
  --silent \
  --show-error \
  --location \
  --request POST \
  --output /tmp/sap-token-response.json \
  --write-out "%{http_code}" \
  --user "${SAP_CLIENT_ID}:${SAP_CLIENT_SECRET}" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "grant_type=client_credentials" \
  "$SAP_TOKEN_URL")

echo "Token HTTP status: $TOKEN_HTTP_CODE"

if [ "$TOKEN_HTTP_CODE" != "200" ]; then
  echo "::error::SAP OAuth token request failed."
  echo "SAP token response:"

  if [ -s /tmp/sap-token-response.json ]; then
    cat /tmp/sap-token-response.json
  else
    echo "Empty response body."
  fi

  echo
  exit 1
fi

ACCESS_TOKEN=$(jq -r '.access_token // empty' \
  /tmp/sap-token-response.json)

if [ -z "$ACCESS_TOKEN" ]; then
  echo "::error::Access token was not returned."
  echo "Token response:"
  cat /tmp/sap-token-response.json
  exit 1
fi

echo "OAuth token generated successfully."

# --------------------------------------------------
# 4. Read CPI design-time artifacts
# --------------------------------------------------

echo
echo "Reading CPI design-time artifacts..."

API_URL="${BASE_URL}/api/v1/IntegrationDesigntimeArtifacts?\$format=json"

echo
echo "CPI API URL:"
echo "$API_URL"

ARTIFACT_HTTP_CODE=$(curl \
  --silent \
  --show-error \
  --location \
  --request GET \
  --output /tmp/cpi-artifacts-response.txt \
  --write-out "%{http_code}" \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --header "Accept: application/json" \
  "$API_URL")

echo
echo "Artifact API HTTP status: $ARTIFACT_HTTP_CODE"

if [ "$ARTIFACT_HTTP_CODE" != "200" ]; then
  echo
  echo "=================================================="
  echo "CPI DESIGN-TIME API CALL FAILED"
  echo "=================================================="

  echo "Requested URL:"
  echo "$API_URL"

  echo
  echo "HTTP status:"
  echo "$ARTIFACT_HTTP_CODE"

  echo
  echo "SAP response:"

  if [ -s /tmp/cpi-artifacts-response.txt ]; then
    cat /tmp/cpi-artifacts-response.txt
  else
    echo "SAP returned an empty response body."
  fi

  echo
  echo "Check the following:"
  echo "1. SAP_BASE_URL points to the CPI tenant management host."
  echo "2. SAP_BASE_URL does not contain an application path."
  echo "3. The API client has Integration Content read/download access."
  echo "=================================================="

  exit 1
fi

# --------------------------------------------------
# 5. Validate OData JSON response
# --------------------------------------------------

if ! jq -e '.d.results | arrays' \
  /tmp/cpi-artifacts-response.txt >/dev/null 2>&1; then

  echo "::error::CPI returned HTTP 200, but the expected OData JSON structure was not found."

  echo
  echo "CPI response:"

  cat /tmp/cpi-artifacts-response.txt

  exit 1
fi

ARTIFACT_RESPONSE=$(cat /tmp/cpi-artifacts-response.txt)

RETURNED_COUNT=$(echo "$ARTIFACT_RESPONSE" |
  jq '.d.results | length')

echo
echo "CPI design-time artifacts retrieved successfully."
echo "Artifacts returned: $RETURNED_COUNT"

# --------------------------------------------------
# 6. Find ReadyForDeployment artifacts
#
# Supported examples:
# 1.0.0.ReadyForDeployment
# 1.0.10.1.ReadyForDeployment
#
# Optional leading v is also accepted:
# v1.0.0.ReadyForDeployment
# --------------------------------------------------

READY_ARTIFACTS=$(echo "$ARTIFACT_RESPONSE" |
  jq -c '
    .d.results[]
    | select(
        .Id != null
        and .Version != null
        and (
          .Version
          | test("^v?[0-9]+\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?\\.ReadyForDeployment$")
        )
      )
  ')

READY_COUNT=$(printf '%s\n' "$READY_ARTIFACTS" |
  sed '/^[[:space:]]*$/d' |
  wc -l)

echo
echo "ReadyF*rDeployment artifacts found: $READ*_COUNT"

if [ "$READY_COUNT" -eq 0 ]; then
  echo
  echo "No artifact*version matched:"
  echo "x.y.z.Re*dyForDeployment"
  echo "x.y.z.w.R*adyForDeployment"
  echo
  echo "N*thing to download."
  exit 0
fi

#*----------------------------------*---------------
# 7. Create output*folder in GitHub workspace
# -----*----------------------------------*---------

if [ -n "${GITHUB_WORKSPACE:-}" ]; then
  ARTIFACT_DIR="${*ITHUB_WORKSPACE}/artifacts"
else
 *ARTIFACT_DIR="${PWD}/artifacts"
fi*
mkdir -p "$ARTIFACT_DIR"

echo
ec*o "Artifact output directory:"
ech* "$ARTIFACT_DIR"

# --------------*----------------------------------*
# 8. Download each matching artif*ct
# -----------------------------*--------------------

DOWNLOADED_C*UNT=0
FAILED_COUNT=0

while IFS= r*ad -r artifact; do

  [ -z "$artifact" ] && continue

  ID=$(echo "$a*tifact" | jq -r '.Id')
  VERSION=$*echo "$artifact" | jq -r '.Version*)
  NAME=$(echo "$artifact" | jq -* '.Name // .Id')
  PACKAGE_ID=$(ec*o "$artifact" | jq -r '.PackageId */ "unknown"')

  echo
  echo "====*==================================*=========="
  echo "Ready artifact*found"
  echo "===================*=============================="
  *cho "Name       : $NAME"
  echo "I*         : $ID"
  echo "Package ID*: $PACKAGE_ID"
  echo "Version    * $VERSION"

  # Escape single quot*s for OData key values
  SAFE_ID=$*ID//\'/\'\'}
  SAFE_VERSION=${VERS*ON//\'/\'\'}

  # Sanitize ID only*for output filename
  SAFE_FILE_ID*$(echo "$ID" |
    sed 's/[^A-Za-z0-9._-]/_/g')

  OUTPUT_FILE="${ART*FACT_DIR}/${SAFE_FILE_ID}.zip"

  *OWNLOAD_URL="${BASE_URL}/api/v1/In*egrationDesigntimeArtifacts(Id='${*AFE_ID}',Version='${SAFE_VERSION}'*/\$value"

  echo
  echo "Download*ng artifact..."
  echo "Output fil*: $OUTPUT_FILE"

  DOWNLOAD_HTTP_C*DE=$(curl \
    --silent \
    --s*ow-error \
    --location \
    --*equest GET \
    --output "$OUTPUT*FILE" \
    --write-out "%{http_co*e}" \
    --header "Authorization:*Bearer ${ACCESS_TOKEN}" \
    --he*der "Accept: application/octet-str*am" \
    "$DOWNLOAD_URL")

  echo*"Download HTTP status: $DOWNLOAD_H*TP_CODE"

  if [ "$DOWNLOAD_HTTP_CODE" != "200" ]; then
    echo "::e*ror::Download failed for artifact $ID."
    echo "HTTP status: $DOWNLOAD_HTTP_CODE"

    if [ -s "$OUTPUT_FILE" ]; then
      echo "SAP response:"
      cat "$OUTPUT_FILE" || true
    fi

    rm -f "$OUTPUT_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi

  if [ ! -s "$OUTPUT_FILE" ]; then
    echo "::error::Downloaded file is empty for artifact $ID."

    rm -f "$OUTPUT_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi

  echo "Validating ZIP file..."

  if ! unzip -t "$OUTPUT_FILE" >/dev/null 2>&1; then
    echo "::error::Downloaded content is not a valid ZIP for artifact $ID."

    echo "Downloaded content type:"
    file "$OUTPUT_FILE" || true

    rm -f "$OUTPUT_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi

  FILE_SIZE=$(du -h "$OUTPUT_FILE" |
    awk '{print $1}')

  echo "Download successful."
  echo "File size: $FILE_SIZE"

  DOWNLOADED_COUNT=$((DOWNLOADED_COUNT + 1))

done <<< "$READY_ARTIFACTS"

# --------------------------------------------------
# 9. Final verification and summary
# --------------------------------------------------

echo
echo "=================================================="
echo "DOWNLOAD SUMMARY"
echo "=================================================="
echo "Ready artifacts found : $READY_COUNT"
echo "Successfully downloaded: $DOWNLOADED_COUNT"
echo "Failed downloads       : $FAILED_COUNT"
echo "Output directory       : $ARTIFACT_DIR"

echo
echo "Downloaded ZIP files:"

find "$ARTIFACT_DIR" \
  -maxdepth 1 \
  -type f \
  -name "*.zip" \
  -print

if [ "$FAILED_COUNT" -gt 0 ]; then
  echo "::error::$FAILED_COUNT artifact download(s) failed."
  exit 1
fi

if [ "$DOWNLOADED_COUNT" -eq 0 ]; then
  echo "::error::ReadyForDeployment artifacts were found, but no ZIP was downloaded successfully."
  exit 1
fi

echo
echo "=================================================="
echo "READYFORDEPLOYMENT DOWNLOAD SUCCESSFUL"
echo "=================================================="
