#!/bin/sh

###
# Apigee OpenLegacy Kickstart (aok) CLI
###

set -e

SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

###
# Check for required variables
###

if [ \
    -z "$OPENLEGACY_APIKEY" -o \
    -z "$OPENLEGACY_HOST" -o \
    -z "$OPENLEGACY_USER" -o \
    -z "$OPENLEGACY_PASS" -o \
    -z "$OPENLEGACY_CODEPAGE" -o \
    -z "$APIGEE_USER" -o \
    -z "$APIGEE_PASS" -o \
    -z "$APIGEE_ORG" -o \
    -z "$APIGEE_ENV" -o \
    -z "$GCP_PROJECT" \
  ]; then
  echo "A required variable is missing"; 
  exit 1
fi


###
# Check for required tools on path
###

for TOOL in mvn ol gcloud jq; do
  if ! which $TOOL > /dev/null; then
    echo "Please ensure $TOOL is installed and on your PATH"
    exit 1
  fi
done

###
# Configure OpenLegacy
###

ol login --api-key "$OPENLEGACY_APIKEY"
ol create module --connector as400-pcml aok-module
cp $SCRIPTPATH/../res/getcst.pcml aok-module/
(cd aok-module/ && ol add --source-path getcst.pcml --host "$OPENLEGACY_HOST" --code-page "$OPENLEGACY_CODEPAGE" --user "$OPENLEGACY_USER" --password "$OPENLEGACY_PASS")
(cd aok-module/ && ol push module)
ol create project aok-project --modules aok-module

###
# Push OpenLegacy Image
###

gcloud services enable containerregistry.googleapis.com run.googleapis.com
gcloud auth configure-docker

# TODO switch project-id to project-name  in json
cat > Dockerfile <<EOF
FROM openlegacy/as400-rpc:1.1.2
RUN mkdir -p /tmp/data
RUN echo '{ \
  "source-provider": { \
    "type": "HUB", \
    "hub": { \
      "project-name": "aok-project", \
      "api-key": "$OPENLEGACY_APIKEY" \
    } \
  } \
}" > /tmp/data/config.json
EOF

docker build -t gcr.io/$GCP_PROJECT/aok-image:latest .
docker push gcr.io/$GCP_PROJECT/aok-image:latest

###
# Deploy OpenLegacy
###

gcloud run deploy aok-service --image gcr.io/$GCP_PROJECT/aok-image:latest --platform managed --region europe-west1 -q
FUNCTION_URL=$(gcloud run services describe aok-service --platform managed --region europe-west1 --format json | jq -r '.status.url')

###
# Get OpenLegacy OpenAPI Specification
###

curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "$FUNCTION_URL/openapi/openapi.yaml" \
  -o openapi.yaml

###
## Generate Service Account for Apigee to call Cloud Run
###

gcloud iam service-accounts create apigee-to-backend --project $GCP_PROJECT
gcloud iam service-accounts keys create credentials.json --iam-account apigee-to-backend@$GCP_PROJECT.iam.gserviceaccount.com
gcloud run services add-iam-policy-binding apigee-to-backend --region europe-west1 --member serviceAccount:apigee-to-backend@$.iam.gserviceaccount.com --role roles/run.invoker --platform managed

###
# Create Apigee Cache for Service Account
###

npx apigeetool createcache -u "$APIGEE_USER" -p "$APIGEE_PASS" -o "$APIGEE_ORG" -e "$APIGEE_ENV" -z gcp-tokens

###
# Push service account json to KVM
###

GCP_SA_KEY=$(jq '. | tostring' < "./credentials.json")
curl -XPOST -s -u "$APIGEE_USER:$APIGEE_PASS" "https://api.enterprise.apigee.com/v1/o/$APIGEE_ORG/e/$APIGEE_ENV/keyvaluemaps" \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary @- > /dev/null << EOF
{
  "name": "service-accounts",
  "encrypted": "true",
  "entry": [
    {
      "name": "cloud-run",
      "value": $GCP_SA_KEY
    }
  ]
}

###
# Deploy Shared Flow to manage JWT token to OpenLegacy
###

npm run deploy --prefix $SCRIPTPATH/../../references/gcp-sa-auth-shared-flow

###
# Generate the Apigee Proxy
###

cp -r proxy target/proxy
SPEC=./target/openapi.json OPERATION=operationId oas-to-am > target/proxy/policies/Assign.OpenLegacy.xml

###
# deploy and test apigee
###

mvn clean install \
  -P"apigeeapi" \
  -Dpassword="${APIGEE_PASS}" \
  -Denv="${env.APIGEE_ENV}" \
  -Dusername="${APIGEE_USER}" \
  -Dorg="${env.APIGEE_ORG}"

### print result
echo "Successfully Apigee OpenLegacy Kickstarter"
