#!/usr/bin/env bash
# Create a security group allowing SSH (22) from your IP and HTTP (80) from anywhere.
# Usage: ./create_security_group.sh   (override with SG_NAME, VPC_ID, SSH_CIDR, ...)

set -euo pipefail

SG_NAME="${SG_NAME:-devops-sg}"
SG_DESCRIPTION="${SG_DESCRIPTION:-Allow SSH and HTTP for AutomationLab}"
PROJECT_TAG="${PROJECT_TAG:-AutomationLab}"
VPC_ID="${VPC_ID:-}"
SSH_CIDR="${SSH_CIDR:-}"
HTTP_CIDR="${HTTP_CIDR:-0.0.0.0/0}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"

export AWS_REGION
export AWS_PAGER=""

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

trap 'die "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

allow_ingress() {
  local port=$1 cidr=$2 description=$3 output
  if output=$(aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":${port},\"ToPort\":${port},\"IpRanges\":[{\"CidrIp\":\"${cidr}\",\"Description\":\"${description}\"}]}]" \
    --tag-specifications "ResourceType=security-group-rule,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
    2>&1); then
    log "Opened port ${port}/tcp to ${cidr}"
  elif [[ "$output" == *"InvalidPermission.Duplicate"* ]]; then
    log "Rule for port ${port}/tcp from ${cidr} already exists, skipping"
  else
    die "Could not open port ${port}: ${output}"
  fi
}

command -v aws >/dev/null 2>&1 || die "AWS CLI is not installed"
[[ -n "$AWS_REGION" ]] || die "No AWS region set. Run 'aws configure' or export AWS_REGION"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are missing or invalid"
log "Region: ${AWS_REGION}"

if [[ -z "$VPC_ID" ]]; then
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
  [[ "$VPC_ID" != "None" ]] ||
    die "No default VPC in ${AWS_REGION}. Run 'aws ec2 create-default-vpc' or set VPC_ID"
fi
log "Using VPC: ${VPC_ID}"

# Restrict SSH to the caller's public IP rather than the whole internet.
if [[ -z "$SSH_CIDR" ]]; then
  MY_IP=$(curl -fsS --max-time 5 https://checkip.amazonaws.com) ||
    die "Could not detect your public IP; set SSH_CIDR manually"
  MY_IP="${MY_IP//[[:space:]]/}"
  [[ "$MY_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Unexpected IP address: ${MY_IP}"
  SSH_CIDR="${MY_IP}/32"
fi
log "SSH will be allowed from: ${SSH_CIDR}"

SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)

if [[ "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "$SG_DESCRIPTION" \
    --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'GroupId' --output text)
  log "Created security group ${SG_NAME}: ${SG_ID}"
else
  log "Security group ${SG_NAME} already exists: ${SG_ID} (reusing)"
fi

allow_ingress 22 "$SSH_CIDR" "SSH access"
allow_ingress 80 "$HTTP_CIDR" "HTTP access"

echo
echo "Security group ID: ${SG_ID}"
echo "Inbound rules:"
aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values="$SG_ID" \
  --query 'SecurityGroupRules[?IsEgress==`false`].{Protocol:IpProtocol,Port:FromPort,Source:CidrIpv4,Description:Description}' \
  --output table
