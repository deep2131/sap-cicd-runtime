#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "SAP CPI - ReadyForDeployment Artifact Downloader"
echo "=================================================="

# ---------------------------------------------
# 1. Validate required environment variables
# ---------------------------------------------

required_vars=(
  SAP_TOKEN_URL
  SAP_CLIENT_ID
  SAP_CLIENT_SECRET
  SAP_BASE_URL
)

for var in "${required_vars[@]}"; do

  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var is not configured."
    exit 1
  fi

done

echo "Required configuration is available."


# ---------------------------------------------
# 2. Generate OAuth token
# ---------------------------------------------

echo
echo "Generating SAP OAuth token..."

TOKEN_RESPONSE=$(curl \
  --fail \
  --silent \
  --show-error \
  --request POST \
  "$SAP_TOKEN_URL" \
  --user "$SAP_CLIENT_ID:$SAP_CLIENT_SECRET" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --data "grant_type=client_credentials")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')

if [ -z "$ACCESS_TOKEN" ]; then

  echo "ERROR: Access token was not returned."
  exit 1

fi

echo "OAuth token generated successfully."


# ---------------------------------------------
# 3. Get design-time artifacts from CPI
# ---------------------------------------------

echo
echo "Reading CPI design-time artifacts..."

ARTIFACT_RESPONSE=$(curl \
  --fail \
  --silent \
  --show-error \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --header "Accept: application/json" \
  "${SAP_BASE_URL}/api/v1/IntegrationDesigntimeArtifacts?\$format=json")


# ---------------------------------------------
# 4. Find versions ending ReadyForDeployment
# ---------------------------------------------

echo
echo "Searching for versions ending with:"
echo ".ReadyForDeployment"

READY_ARTIFACTS=$(echo "$ARTIFACT_RESPONSE" | \
  jq -c '
    .d.results[]
    | select(
        .Version != null
        and (.Version | endswith(".ReadyForDeployment"))
      )
  ')


# ---------------------------------------------
# 5. Nothing found
# ---------------------------------------------

if [ -z "$READY_ARTIFACTS" ]; then

  echo
  echo "No ReadyForDeployment artifacts found."
  echo
  echo "Nothing to download."

  exit 0

fi


# ---------------------------------------------
# 6. Create destination folder
# ---------------------------------------------

mkdir -p artifacts


# ---------------------------------------------
# 7. Download matching artifacts
# ---------------------------------------------

COUNT=0

while IFS= read -r artifact
do

  [ -z "$artifact" ] && continue

  ID=$(echo "$artifact" | jq -r '.Id')
  VERSION=$(echo "$artifact" | jq -r '.Version')
  NAME=$(echo "$artifact" | jq -r '.Name // .Id')

  echo
  echo "=================================================="
  echo "Ready artifact found"
  echo "=================================================="
  echo "Name    : $NAME"
  echo "ID      : $ID"
  echo "Version : $VERSION"


  # Escape single quotes for OData string keys
  SAFE_ID=${ID//\'/\'\'}
  SAFE_VERSION=${VERSION//\'/\'\'}

  DOWNLOAD_URL="${SAP_BASE_URL}/api/v1/IntegrationDesigntimeArtifacts(Id='${SAFE_ID}',Version='${SAFE_VERSION}')/\$value"

  OUTPUT_FILE="artifacts/${ID}.zip"

  echo
  echo "Downloading $ID..."

  HTTP_CODE=$(curl \
    --silent \
    --show-error \
    --location \
    --output "$OUTPUT_FILE" \
    --write-out "%{http_code}" \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    "$DOWNLOAD_URL")


  if [ "$HTTP_CODE" != "200" ]; then

    echo "ERROR: Download failed."
    echo "Artifact: $ID"
    echo "HTTP status: $HTTP_CODE"

    rm -f "$OUTPUT_FILE"

    exit 1

  fi


  # -----------------------------------------
  # 8. Verify file exists
  # -----------------------------------------

  if [ ! -s "$OUTPUT_FILE" ]; then

    echo "ERROR: Downloaded file is empty."
    echo "Artifact: $ID"

    exit 1

  fi


  # -----------------------------------------
  # 9. Verify ZIP
  # -----------------------------------------

  echo "Validating ZIP..."

  if ! unzip -t "$OUTPUT_FILE" >/dev/null; then

    echo "ERROR: Downloaded artifact is not a valid ZIP."
    echo "Artifact: $ID"

    exit 1

  fi


  echo "SUCCESS: $ID downloaded."

  COUNT=$((COUNT + 1))

done <<< "$READY_ARTIFACTS"


# ---------------------------------------------
# 10. Final summary
# ---------------------------------------------

echo
echo "=================================================="
echo "DOWNLOAD COMPLETED"
echo "=================================================="

echo "Artifacts downloaded: $COUNT"

echo
echo "Downloaded files:"

find artifacts -maxdepth 1 -type f -name "*.zip" -print

echo "=================================================="
