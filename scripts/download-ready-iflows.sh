#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "SAP CPI - OData Metadata Diagnostic"
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

  echo
  echo "SAP response:"

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
  exit 1
fi

echo "OAuth token generated successfully."

# --------------------------------------------------
# 4. Call OData metadata endpoint
# --------------------------------------------------

echo
echo "Reading CPI OData metadata..."

API_URL="${BASE_URL}/api/v1/\$metadata"

echo
echo "CPI API URL:"
echo "$API_URL"

METADATA_HTTP_CODE=$(curl \
  --silent \
  --show-error \
  --location \
  --request GET \
  --output /tmp/cpi-metadata.xml \
  --write-out "%{http_code}" \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --header "Accept: application/xml" \
  "$API_URL")

echo
echo "Metadata HTTP status: $METADATA_HTTP_CODE"

if [ "$METADATA_HTTP_CODE" != "200" ]; then

  echo
  echo "=================================================="
  echo "CPI METADATA API CALL FAILED"
  echo "=================================================="

  echo
  echo "Requested URL:"
  echo "$API_URL"

  echo
  echo "HTTP status:"
  echo "$METADATA_HTTP_CODE"

  echo
  echo "SAP response:"

  if [ -s /tmp/cpi-metadata.xml ]; then
    cat /tmp/cpi-metadata.xml
  else
    echo "SAP returned an empty response body."
  fi

  echo
  exit 1
fi

echo
echo "Metadata endpoint successfully returned HTTP 200."

# --------------------------------------------------
# 5. Search metadata for IntegrationDesigntimeArtifacts
# --------------------------------------------------

echo
echo "=================================================="
echo "Checking available OData entities"
echo "=================================================="

if grep -q 'IntegrationDesigntimeArtifacts' \
  /tmp/cpi-metadata.xml; then

  echo
  echo "SUCCESS:"
  echo "IntegrationDesigntimeArtifacts exists in metadata."

  echo
  echo "Matching metadata entries:"

  grep -o '.\{0,100\}IntegrationDesigntimeArtifacts.\{0,150\}' \
    /tmp/cpi-metadata.xml \
    | head -20 \
    || true

  echo
  echo "=================================================="
  echo "METADATA DIAGNOSTIC SUCCESSFUL"
  echo "=================================================="

  exit 0

fi

# --------------------------------------------------
# 6. Entity not found
# --------------------------------------------------

echo
echo "::error::IntegrationDesigntimeArtifacts was NOT found in metadata."

echo
echo "Available EntitySets:"
echo

grep -o 'EntitySet Name="[^"]*"' \
  /tmp/cpi-metadata.xml \
  | sort \
  | head -100 \
  || true

echo
echo "=================================================="
echo "METADATA DIAGNOSTIC FAILED"
echo "=================================================="

exit 1
