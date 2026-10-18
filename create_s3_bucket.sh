#!/usr/bin/env bash
# Create a uniquely named, versioned, private S3 bucket and upload a welcome.txt file.
# Usage: ./create_s3_bucket.sh   (override with BUCKET_NAME, BUCKET_PREFIX, PROJECT_TAG)

set -euo pipefail

BUCKET_PREFIX="${BUCKET_PREFIX:-automationlab}"
BUCKET_NAME="${BUCKET_NAME:-}"
PROJECT_TAG="${PROJECT_TAG:-AutomationLab}"
OBJECT_KEY="${OBJECT_KEY:-welcome.txt}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"

export AWS_REGION
export AWS_PAGER=""

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'die "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

command -v aws >/dev/null 2>&1 || die "AWS CLI is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"
[[ -n "$AWS_REGION" ]] || die "No AWS region set. Run 'aws configure' or export AWS_REGION"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are missing or invalid"
log "Region: ${AWS_REGION}"

if [[ -z "$BUCKET_NAME" ]]; then
  BUCKET_NAME=$(aws resourcegroupstaggingapi get-resources \
    --resource-type-filters s3 \
    --tag-filters Key=Project,Values="$PROJECT_TAG" \
    --query 'ResourceTagMappingList[0].ResourceARN' --output text)
  if [[ "$BUCKET_NAME" != "None" ]]; then
    BUCKET_NAME="${BUCKET_NAME#arn:aws:s3:::}"
    log "Found existing ${PROJECT_TAG} bucket: ${BUCKET_NAME} (reusing)"
  else
    SUFFIX=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
    BUCKET_NAME="${BUCKET_PREFIX}-${AWS_REGION}-${SUFFIX}"
  fi
fi

[[ "$BUCKET_NAME" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
  die "Invalid bucket name '${BUCKET_NAME}': use 3-63 lowercase letters, digits, dots or hyphens"

# us-east-1 is the only region that rejects an explicit LocationConstraint.
if [[ "$AWS_REGION" == "us-east-1" ]]; then
  LOCATION_ARGS=()
else
  LOCATION_ARGS=(--create-bucket-configuration "LocationConstraint=${AWS_REGION}")
fi

if output=$(aws s3api create-bucket --bucket "$BUCKET_NAME" "${LOCATION_ARGS[@]}" 2>&1); then
  log "Created bucket ${BUCKET_NAME}"
elif [[ "$output" == *"BucketAlreadyOwnedByYou"* ]]; then
  log "Bucket ${BUCKET_NAME} already exists in your account (reusing)"
elif [[ "$output" == *"BucketAlreadyExists"* ]]; then
  die "Bucket name ${BUCKET_NAME} is taken by another AWS account; choose another BUCKET_NAME"
else
  die "Could not create bucket: ${output}"
fi

aws s3api wait bucket-exists --bucket "$BUCKET_NAME"

aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
log "Public access blocked"

aws s3api put-bucket-tagging --bucket "$BUCKET_NAME" \
  --tagging "TagSet=[{Key=Name,Value=${BUCKET_NAME}},{Key=Project,Value=${PROJECT_TAG}}]"
log "Tagged with Project=${PROJECT_TAG}"

aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled
log "Versioning enabled"

aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
log "Default encryption set (SSE-S3)"

cat >"${TMP_DIR}/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    }
  ]
}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy "file://${TMP_DIR}/policy.json"
log "Bucket policy applied (HTTPS only)"

cat >"${TMP_DIR}/${OBJECT_KEY}" <<EOF
Welcome to the ${PROJECT_TAG} S3 bucket!
Uploaded by create_s3_bucket.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC').
EOF
VERSION_ID=$(aws s3api put-object --bucket "$BUCKET_NAME" --key "$OBJECT_KEY" \
  --body "${TMP_DIR}/${OBJECT_KEY}" --content-type text/plain \
  --query 'VersionId' --output text)
log "Uploaded ${OBJECT_KEY} (version ${VERSION_ID})"

echo
echo "Bucket:     ${BUCKET_NAME}"
echo "Region:     ${AWS_REGION}"
echo "Versioning: $(aws s3api get-bucket-versioning --bucket "$BUCKET_NAME" --query 'Status' --output text)"
echo "Policy:"
aws s3api get-bucket-policy --bucket "$BUCKET_NAME" --query 'Policy' --output text | jq .
echo "Objects:"
aws s3api list-object-versions --bucket "$BUCKET_NAME" \
  --query 'Versions[].{Key:Key,VersionId:VersionId,Latest:IsLatest,Size:Size,Modified:LastModified}' \
  --output table
