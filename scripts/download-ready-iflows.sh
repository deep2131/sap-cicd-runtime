#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "SAP CPI - ReadyForDeployment Artifact Downloader"
echo "=================================================="

# ==================================================
# 1. Validate required environment variables
# ==================================================

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
echo "Required SAP configuration is available."

# ==================================================
# 2. Normalize SAP base URL
# ==================================================

BASE_URL="${SAP_BASE_URL%/}"

# Remove API paths if accidentally included in SAP_BASE_URL
BASE_URL="${BASE_URL%/api/v1/IntegrationDesigntimeArtifacts}"
BASE_URL="${BASE_URL%/api/v1}"

echo
echo "SAP base host:"
echo "$BASE_URL"

# ==================================================
# 3. Generate OAuth token
# ==================================================

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

  echo
  echo "SAP token response:"

  if [ -s /tmp/sap-token-response.json ]; then
    cat /tmp/sap-token-response.json
  else
    echo "SAP returned an empty response body."
  fi

  echo
  exit 1
fi

ACCESS_TOKEN=$(jq -r '.access_token // empty' \
  /tmp/sap-token-response.json)

if [ -z "$ACCESS_TOKEN" ]; then
  echo "::error::Access token was not returned."

  echo
  echo "Token response:"
  cat /tmp/sap-token-response.json

  exit 1
fi

echo "OAuth token generated successfully."

# ==================================================
# 4. Read CPI design-time artifacts
#
# Important:
# Do not add ?$format=json here.
# The same API previously returned HTTP 501 when
# called with that query option.
# ==================================================

echo
echo "Reading CPI design-time artifacts..."

API_URL="${BASE_URL}/api/v1/IntegrationDesigntimeArtifacts"

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

  echo
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
  exit 1
fi

echo "CPI design-time API request completed successfully."

# ==================================================
# 5. Validate the returned JSON structure
#
# SAP OData V2 normally returns:
# {
#   "d": {
#     "results": [...]
#   }
# }
#
# The fallback supports:
# {
#   "value": [...]
# }
# ==================================================

if jq -e '.d.results | arrays' \
  /tmp/cpi-artifacts-response.txt >/dev/null 2>&1; then

  RESPONSE_FORMAT="odata-v2"

elif jq -e '.value | arrays' \
  /tmp/cpi-artifacts-response.txt >/dev/null 2>&1; then

  RESPONSE_FORMAT="value-array"

else
  echo "::error::CPI returned HTTP 200, but the expected artifact JSON structure was not found."

  echo
  echo "Response sample:"
  head -c 4000 /tmp/cpi-artifacts-response.txt
  echo

  exit 1
fi

echo
echo "Detected response format: $RESPONSE_FORMAT"

if [ "$RESPONSE_FORMAT" = "odata-v2" ]; then
  RETURNED_COUNT=$(jq '.d.results | length' \
    /tmp/cpi-artifacts-response.txt)
else
  RETURNED_COUNT=$(jq '.value | length' \
    /tmp/cpi-artifacts-response.txt)
fi

echo "Artifacts returned: $RETURNED_COUNT"

# ==================================================
# 6. Find versions marked ReadyForDeployment
#
# Supported:
# 1.0.0.ReadyForDeployment
# 1.0.10.1.ReadyForDeployment
# v1.0.0.ReadyForDeployment
# v1.0.10.1.ReadyForDeployment
#
# Not selected:
# 1.0.0
# 1.0.ReadyForDeployment
# ReadyForDeployment
# ==================================================

READY_FILTER='
  select(
    .Id != null
    and .Version != null
    and (
      .Version
      | test(
          "^[0-9]+\\.[0-9]+\\.[0-9]+(\\.[0-9]+)?\\.ReadyForDeployment$"
        )
    )
  )
'

if [ "$RESPONSE_FORMAT" = "odata-v2" ]; then

  READY_ARTIFACTS=$(jq -c \
    ".d.results[] | ${READY_FILTER}" \
    /tmp/cpi-artifacts-response.txt)

else

  READY_ARTIFACTS=$(jq -c \
    ".value[] | ${READY_FILTER}" \
    /tmp/cpi-artifacts-response.txt)

fi

READY_COUNT=$(printf '%s\n' "$READY_ARTIFACTS" \
  | sed '/^[[:space:]]*$/d' \
  | wc -l \
  | tr -d ' ')
*echo
echo "ReadyForDeployment arti*acts found: $READY_COUNT"

if [ "$READY_COUNT" -eq 0 ]; then
  echo
 *echo "No artifact version matched *he supported patterns:"
  echo "x.*.z.ReadyForDeployment"
  echo "x.y*z.w.ReadyForDeployment"
  echo "vx*y.z.ReadyForDeployment"
  echo "vx*y.z.w.ReadyForDeployment"
  echo
 *echo "Nothing to download."

  exi* 0
fi

# =========================*========================
# 7. Crea*e output directory
# =============*==================================*=

if [ -n "${GITHUB_WORKSPACE:-}" ]; then
  ARTIFACT_DIR="${GITHUB_W*RKSPACE}/artifacts"
else
  ARTIFAC*_DIR="${PWD}/artifacts"
fi

mkdir *p "$ARTIFACT_DIR"

echo
echo "Arti*act output directory:"
echo "$ARTI*ACT_DIR"

# ======================*===========================
# 8. D*wnload each matching artifact
# ==*==================================*============

DOWNLOADED_COUNT=0
F*ILED_COUNT=0

while IFS= read -r a*tifact; do

  [ -z "$artifact" ] &* continue

  ID=$(echo "$artifact"*| jq -r '.Id')
  VERSION=$(echo "$*rtifact" | jq -r '.Version')
  NAM*=$(echo "$artifact" | jq -r '.Name*// .Id')
  PACKAGE_ID=$(echo "$art*fact" | jq -r '.PackageId // "unkn*wn"')

  echo
  echo "============*==================================*=="
  echo "ReadyForDeployment art*fact found"
  echo "==============*==================================*"
  echo "Name       : $NAME"
  ec*o "ID         : $ID"
  echo "Packa*e ID : $PACKAGE_ID"
  echo "Versio*    : $VERSION"

  # Escape single*quotes for OData key values
  SAFE*ID="${ID//\'/\'\'}"
  SAFE_VERSION*"${VERSION//\'/\'\'}"

  # Sanitiz* values used in the output filenam*
  SAFE_FILE_ID=$(printf '%s' "$ID* \
    | sed 's/[^A-Za-z0-9._-]/_/*')

  SAFE_FILE_VERSION=$(printf '*s' "$VERSION" \
    | sed 's/[^A-Za-z0-9._-]/_/g')

  OUTPUT_FILE="${*RTIFACT_DIR}/${SAFE_FILE_ID}_${SAF*_FILE_VERSION}.zip"

  DOWNLOAD_UR*="${BASE_URL}/api/v1/IntegrationDe*igntimeArtifacts(Id='${SAFE_ID}',V*rsion='${SAFE_VERSION}')/\$value"
*  echo
  echo "Downloading artifac*..."
  echo "Output file: $OUTPUT_*ILE"

  DOWNLOAD_HTTP_CODE=$(curl *
    --silent \
    --show-error \*    --location \
    --request GET*\
    --output "$OUTPUT_FILE" \
  * --write-out "%{http_code}" \
    *-header "Authorization: Bearer ${A*CESS_TOKEN}" \
    --header "Accep*: application/octet-stream" \
    *$DOWNLOAD_URL")

  echo "Download *TTP status: $DOWNLOAD_HTTP_CODE"

* if [ "$DOWNLOAD_HTTP_CODE" != "200" ]; then
    echo "::error::Downl*ad failed for artifact $ID."
    e*ho "HTTP status: $DOWNLOAD_HTTP_CO*E"

    if [ -s "$OUTPUT_FILE" ]; *hen
      echo
      echo "SAP res*onse:"
      cat "$OUTPUT_FILE" ||*true
      echo
    fi

    rm -f *$OUTPUT_FILE"

    FAILED_COUNT=$(*FAILED_COUNT + 1))
    continue
  *i

  if [ ! -s "$OUTPUT_FILE" ]; t*en
    echo "::error::Downloaded f*le is empty for artifact $ID."

  * rm -f "$OUTPUT_FILE"

    FAILED_*OUNT=$((FAILED_COUNT + 1))
    con*inue
  fi

  echo "Validating down*oaded ZIP..."

  if ! unzip -t "$OUTPUT_FILE" >/dev/null 2>&1; then
    echo "::error::Downloaded content is not a valid ZIP for artifact $ID."

    rm -f "$OUTPUT_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi

  FILE_SIZE=$(du -h "$OUTPUT_FILE" | awk '{print $1}')

  echo "Download successful."
  echo "File size: $FILE_SIZE"

  DOWNLOADED_COUNT=$((DOWNLOADED_COUNT + 1))

done <<< "$READY_ARTIFACTS"

# ==================================================
# 9. Final verification
# ==================================================

echo
echo "=================================================="
echo "DOWNLOAD SUMMARY"
echo "=================================================="
echo "CPI artifacts returned       : $RETURNED_COUNT"
echo "ReadyForDeployment artifacts : $READY_COUNT"
echo "Successfully downloaded      : $DOWNLOADED_COUNT"
echo "Failed downloads             : $FAILED_COUNT"
echo "Output directory             : $ARTIFACT_DIR"

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
  echo "::error::ReadyForDeployment artifacts were found, but no ZIP file was downloaded successfully."
  exit 1
fi

echo
echo "=================================================="
echo "READYFORDEPLOYMENT DOWNLOAD SUCCESSFUL"
echo "=================================================="
