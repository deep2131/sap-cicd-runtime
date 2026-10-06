#!/usr/bin/env bash
*set -euo pipefail

echo "=========*=============================="
ec*o "SAP ReadyForDeployment Artifact*Download"
echo "==================*====================="

required_v*rs=(
  SAP_TOKEN_URL
  SAP_CLIENT_*D
  SAP_CLIENT_SECRET
  SAP_BASE_U*L
)

for var in "${required_vars[@*}"; do
  if [ -z "${!var:-}" ]; th*n
    echo "ERROR: $var is not con*igured"
    exit 1
  fi
done

echo*"Environment validation passed."

* ---------------------------------*-------
# Get OAuth token
# ------*----------------------------------*
echo
echo "Getting SAP OAuth toke*..."

TOKEN_RESPONSE=$(curl --fail*--silent --show-error \
  --reques* POST \
  "$SAP_TOKEN_URL" \
  --u*er "$SAP_CLIENT_ID:$SAP_CLIENT_SEC*ET" \
  --header "Content-Type: ap*lication/x-www-form-urlencoded" \
* --data "grant_type=client_credent*als")

ACCESS_TOKEN=$(echo "$TOKEN*RESPONSE" | jq -r '.access_token /* empty')

if [ -z "$ACCESS_TOKEN" *; then
  echo "ERROR: Access token*was not returned."
  exit 1
fi

ec*o "Token generated successfully."
*# --------------------------------*--------
# Get design-time artifac*s
# ------------------------------*----------

echo
echo "Getting CPI*design-time artifacts..."

RESPONS*=$(curl --fail --silent --show-err*r \
  --header "Authorization: Bea*er ${ACCESS_TOKEN}" \
  --header "*ccept: application/json" \
  "${SA*_BASE_URL}/api/v1/IntegrationDesig*timeArtifacts?\$format=json")

# -*----------------------------------*----
# Find Version = ReadyForDepl*yment
# --------------------------*--------------

echo
echo "Searchi*g for Version = ReadyForDeployment*.."

READY_ARTIFACTS=$(echo "$RESP*NSE" | jq -c \
  '.d.results[] | s*lect(.Version == "ReadyForDeployme*t")')

if [ -z "$READY_ARTIFACTS" *; then
  echo
  echo "No artifacts*with Version=ReadyForDeployment fo*nd."
  exit 0
fi

mkdir -p artifac*s

COUNT=0

# --------------------*--------------------
# Download ev*ry matching artifact
# -----------*-----------------------------

whi*e IFS= read -r artifact
do

  [ -z*"$artifact" ] && continue

  ID=$(*cho "$artifact" | jq -r '.Id')
  V*RSION=$(echo "$artifact" | jq -r '*Version')
  NAME=$(echo "$artifact* | jq -r '.Name // .Id')
  PACKAGE*ID=$(echo "$artifact" | jq -r '.Pa*kageId // "unknown"')

  echo
  ec*o "-------------------------------*--------"
  echo "Artifact : $NAME*
  echo "ID       : $ID"
  echo "P*ckage  : $PACKAGE_ID"
  echo "Vers*on  : $VERSION"
  echo "----------*-----------------------------"

  *OWNLOAD_URL="${SAP_BASE_URL}/api/v*/IntegrationDesigntimeArtifacts(Id*'${ID}',Version='${VERSION}')/\$va*ue"

  OUTPUT_FILE="artifacts/${ID*.zip"

  HTTP_CODE=$(curl --silent*\
    --show-error \
    --locatio* \
    --output "$OUTPUT_FILE" \
 *  --write-out "%{http_code}" \
   *--header "Authorization: Bearer ${*CCESS_TOKEN}" \
    "$DOWNLOAD_URL*)

  if [ "$HTTP_CODE" != "200" ];*then
    echo "ERROR: Download fai*ed for $ID"
    echo "HTTP status:*$HTTP_CODE"

    rm -f "$OUTPUT_FI*E"
    exit 1
  fi

  if [ ! -s "$*UTPUT_FILE" ]; then
    echo "ERRO*: Downloaded artifact is empty: $I*"
    exit 1
  fi

  echo "Downloa* successful."

  echo "Validating *IP..."

  unzip -t "$OUTPUT_FILE"
*  COUNT=$((COUNT + 1))

done <<< "*READY_ARTIFACTS"


echo
echo "====*==================================*"
echo "DOWNLOAD COMPLETE"
echo "A*tifacts downloaded: $COUNT"
echo "*==================================*===="

find artifacts -type f -max*epth 2 -print
