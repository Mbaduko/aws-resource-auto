#!/usr/bin/env bash
# Delete every resource tagged Project=<PROJECT_TAG>: EC2 instances, security groups,
# key pairs (and their local .pem files) and S3 buckets (including all object versions).
# Usage: ./cleanup_resources.sh [--dry-run] [--yes]

set -euo pipefail

# Settings; DRY_RUN and ASSUME_YES can only be turned on by flags, never by the environment
PROJECT_TAG="${PROJECT_TAG:-AutomationLab}"
KEY_DIR="${KEY_DIR:-$HOME/.ssh}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
DRY_RUN=false
ASSUME_YES=false

export AWS_REGION
export AWS_PAGER=""

# Messages go to stderr so stdout only carries results
log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# Scratch folder for delete batches, removed however the script exits
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'die "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--yes]
  -n, --dry-run   Only list what would be deleted
  -y, --yes       Delete without asking for confirmation
  -h, --help      Show this help
Resources are selected by the tag Project=${PROJECT_TAG} in region ${AWS_REGION:-<unset>}.
EOF
}

# Parse options; unknown ones are an error so a typo never triggers a real deletion
while (($#)); do
  case "$1" in
    -n | --dry-run) DRY_RUN=true ;;
    -y | --yes) ASSUME_YES=true ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

delete_security_group() {
  local sg_id=$1 attempt output
  # Network interfaces of just-terminated instances can take a moment to detach.
  for attempt in {1..12}; do
    if output=$(aws ec2 delete-security-group --group-id "$sg_id" 2>&1); then
      log "Deleted security group ${sg_id}"
      return 0
    elif [[ "$output" == *"DependencyViolation"* && $attempt -lt 12 ]]; then
      log "Security group ${sg_id} still in use, retrying in 10s (${attempt}/12)"
      sleep 10
    else
      die "Could not delete security group ${sg_id}: ${output}"
    fi
  done
}

# A versioned bucket is only empty once every version and delete marker is gone
empty_bucket() {
  local bucket=$1 versions batch_file="${TMP_DIR}/delete.json" count errors
  while true; do
    versions=$(aws s3api list-object-versions --bucket "$bucket" --max-items 1000 --output json)
    jq '{Objects: ([.Versions[]?, .DeleteMarkers[]?] | map({Key, VersionId}) | .[0:1000]), Quiet: true}' \
      <<<"$versions" >"$batch_file"
    count=$(jq '.Objects | length' "$batch_file")
    ((count > 0)) || break
    # delete-objects exits 0 even when some deletes fail, so count the reported errors
    errors=$(aws s3api delete-objects --bucket "$bucket" --delete "file://${batch_file}" \
      --query 'length(Errors || `[]`)' --output text)
    [[ "$errors" == "0" ]] || die "Failed to delete ${errors} object(s) from ${bucket}"
    log "Deleted ${count} object version(s) from ${bucket}"
  done
}

# Preflight: tools installed, region set, credentials valid
command -v aws >/dev/null 2>&1 || die "AWS CLI is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"
[[ -n "$AWS_REGION" ]] || die "No AWS region set. Run 'aws configure' or export AWS_REGION"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are missing or invalid"
log "Region: ${AWS_REGION} | Looking for resources tagged Project=${PROJECT_TAG}"

# Discover resources strictly by tag; nothing untagged is ever selected
json=$(aws ec2 describe-instances \
  --filters Name=tag:Project,Values="$PROJECT_TAG" \
            Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output json)
mapfile -t INSTANCE_IDS < <(jq -r '.[]' <<<"$json")

json=$(aws ec2 describe-security-groups \
  --filters Name=tag:Project,Values="$PROJECT_TAG" \
  --query 'SecurityGroups[].GroupId' --output json)
mapfile -t SG_IDS < <(jq -r '.[]' <<<"$json")

json=$(aws ec2 describe-key-pairs \
  --filters Name=tag:Project,Values="$PROJECT_TAG" \
  --query 'KeyPairs[].KeyName' --output json)
mapfile -t KEY_NAMES < <(jq -r '.[]' <<<"$json")

json=$(aws resourcegroupstaggingapi get-resources \
  --resource-type-filters s3 \
  --tag-filters Key=Project,Values="$PROJECT_TAG" \
  --query 'ResourceTagMappingList[].ResourceARN' --output json)
mapfile -t TAGGED_BUCKETS < <(jq -r '.[] | sub("^arn:aws:s3:::"; "")' <<<"$json")
BUCKETS=()
for bucket in "${TAGGED_BUCKETS[@]}"; do
  # The tagging API can briefly list buckets that were already deleted.
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    BUCKETS+=("$bucket")
  fi
done

# Always show what was found before doing anything
echo
echo "Resources tagged Project=${PROJECT_TAG} in ${AWS_REGION}:"
echo "  EC2 instances:   ${INSTANCE_IDS[*]:-none}"
echo "  Security groups: ${SG_IDS[*]:-none}"
echo "  Key pairs:       ${KEY_NAMES[*]:-none}"
echo "  S3 buckets:      ${BUCKETS[*]:-none}"
echo

total=$((${#INSTANCE_IDS[@]} + ${#SG_IDS[@]} + ${#KEY_NAMES[@]} + ${#BUCKETS[@]}))
if ((total == 0)); then
  log "Nothing to clean up"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  log "Dry run: nothing was deleted"
  exit 0
fi

# Require an explicit "yes", or --yes when no one is at the terminal
if [[ "$ASSUME_YES" != true ]]; then
  [[ -t 0 ]] || die "Not running interactively; pass --yes to confirm deletion"
  read -r -p "Permanently delete these ${total} resource(s)? Type 'yes' to continue: " answer
  [[ "$answer" == "yes" ]] || die "Aborted by user"
fi

# Delete in dependency order: instances -> security groups -> key pairs -> buckets
if ((${#INSTANCE_IDS[@]} > 0)); then
  aws ec2 terminate-instances --instance-ids "${INSTANCE_IDS[@]}" >/dev/null
  log "Terminating ${INSTANCE_IDS[*]}, waiting..."
  aws ec2 wait instance-terminated --instance-ids "${INSTANCE_IDS[@]}"
  log "Instances terminated"
fi

for sg_id in "${SG_IDS[@]}"; do
  delete_security_group "$sg_id"
done

for key_name in "${KEY_NAMES[@]}"; do
  aws ec2 delete-key-pair --key-name "$key_name" >/dev/null
  log "Deleted key pair ${key_name}"
  if [[ -f "${KEY_DIR}/${key_name}.pem" ]]; then
    rm -f "${KEY_DIR}/${key_name}.pem"
    log "Removed local key file ${KEY_DIR}/${key_name}.pem"
  fi
done

for bucket in "${BUCKETS[@]}"; do
  empty_bucket "$bucket"
  aws s3api delete-bucket --bucket "$bucket"
  log "Deleted bucket ${bucket}"
done

echo
log "Cleanup complete: ${total} resource(s) removed"
