#!/usr/bin/env bash
# Create a key pair and launch a tagged Amazon Linux 2 EC2 instance running a web server.
# Usage: ./create_ec2.sh   (override with KEY_NAME, INSTANCE_TYPE, SG_NAME, ...)
# Requires: the security group from create_security_group.sh

set -euo pipefail

KEY_NAME="${KEY_NAME:-automationlab-key}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
INSTANCE_NAME="${INSTANCE_NAME:-automationlab-web}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
SG_NAME="${SG_NAME:-devops-sg}"
PROJECT_TAG="${PROJECT_TAG:-AutomationLab}"
AMI_PARAMETER="${AMI_PARAMETER:-/aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"

export AWS_REGION
export AWS_PAGER=""

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

trap 'die "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

tags() {
  local resource_type=$1
  echo "ResourceType=${resource_type},Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_TAG}}]"
}

command -v aws >/dev/null 2>&1 || die "AWS CLI is not installed"
[[ -n "$AWS_REGION" ]] || die "No AWS region set. Run 'aws configure' or export AWS_REGION"
aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials are missing or invalid"
log "Region: ${AWS_REGION}"

EXISTING_ID=$(aws ec2 describe-instances \
  --filters Name=tag:Name,Values="$INSTANCE_NAME" Name=tag:Project,Values="$PROJECT_TAG" \
            Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].InstanceId | [0]' --output text)
if [[ "$EXISTING_ID" != "None" ]]; then
  log "Instance ${INSTANCE_NAME} already exists: ${EXISTING_ID} (not launching another)"
  INSTANCE_ID="$EXISTING_ID"
else
  # The private key is only returned once, at creation; never overwrite or lose it.
  KEY_IN_AWS=$(aws ec2 describe-key-pairs \
    --filters Name=key-name,Values="$KEY_NAME" \
    --query 'KeyPairs[0].KeyName' --output text)
  if [[ "$KEY_IN_AWS" != "None" && -f "$KEY_FILE" ]]; then
    log "Key pair ${KEY_NAME} already exists, using ${KEY_FILE}"
  elif [[ "$KEY_IN_AWS" != "None" ]]; then
    die "Key pair ${KEY_NAME} exists in AWS but ${KEY_FILE} is missing. Delete it with 'aws ec2 delete-key-pair --key-name ${KEY_NAME}' or set KEY_NAME"
  elif [[ -f "$KEY_FILE" ]]; then
    die "${KEY_FILE} already exists locally. Move it away or set KEY_FILE"
  else
    mkdir -p "$(dirname "$KEY_FILE")"
    (
      umask 077
      aws ec2 create-key-pair \
        --key-name "$KEY_NAME" \
        --key-type ed25519 \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=${KEY_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
        --query 'KeyMaterial' --output text >"$KEY_FILE"
    ) || { rm -f "$KEY_FILE"; die "Failed to create key pair ${KEY_NAME}"; }
    chmod 400 "$KEY_FILE"
    log "Created key pair ${KEY_NAME}, private key saved to ${KEY_FILE}"
  fi

  SG_ID=$(aws ec2 describe-security-groups \
    --filters Name=group-name,Values="$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)
  [[ "$SG_ID" != "None" ]] || die "Security group ${SG_NAME} not found. Run ./create_security_group.sh first"
  VPC_ID=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].VpcId' --output text)
  log "Using security group ${SG_NAME}: ${SG_ID} (VPC ${VPC_ID})"

  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
    --query 'Subnets[0].SubnetId' --output text)
  [[ "$SUBNET_ID" != "None" ]] || die "No public subnet found in ${VPC_ID}"
  log "Using subnet: ${SUBNET_ID}"

  AMI_ID=$(aws ssm get-parameter --name "$AMI_PARAMETER" --query 'Parameter.Value' --output text)
  ROOT_DEVICE=$(aws ec2 describe-images --image-ids "$AMI_ID" \
    --query 'Images[0].RootDeviceName' --output text)
  log "Using AMI: ${AMI_ID}"

  FREE_TIER=$(aws ec2 describe-instance-types --instance-types "$INSTANCE_TYPE" \
    --query 'InstanceTypes[0].FreeTierEligible' --output text)
  [[ "$FREE_TIER" == "True" ]] || log "WARNING: ${INSTANCE_TYPE} is not free-tier eligible in this account"

  USER_DATA=$(cat <<'EOF'
#!/bin/bash
yum install -y httpd
echo "<h1>AutomationLab: deployed by create_ec2.sh on $(hostname -f)</h1>" > /var/www/html/index.html
systemctl enable --now httpd
EOF
)

  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --count 1 \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled \
    --block-device-mappings "DeviceName=${ROOT_DEVICE},Ebs={Encrypted=true,VolumeType=gp3,DeleteOnTermination=true}" \
    --user-data "$USER_DATA" \
    --tag-specifications "$(tags instance)" "$(tags volume)" \
    --query 'Instances[0].InstanceId' --output text)
  log "Launched instance ${INSTANCE_ID}, waiting for it to be running..."
fi

aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

DETAILS=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text)
read -r STATE PUBLIC_IP <<<"$DETAILS"

echo
echo "Instance ID: ${INSTANCE_ID}"
echo "State:       ${STATE}"
echo "Public IP:   ${PUBLIC_IP}"
echo "SSH:         ssh -i ${KEY_FILE} ec2-user@${PUBLIC_IP}"
echo "Website:     http://${PUBLIC_IP}  (allow 1-2 minutes for the web server to install)"
