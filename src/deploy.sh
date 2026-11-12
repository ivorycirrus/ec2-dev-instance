#!/usr/bin/env bash
# Deploy an EC2 instance in a private subnet (NAT egress) that is reachable
# only through Systems Manager. No key pair, no inbound ports.
#
# Source file. scripts/build.sh merges it with ec2-ssh-remote.yaml (CloudFormation
# template) and user-data.sh into dist/deploy.sh, which runs on its own.
# This file also runs as is from src/, reading those two files next to it.
#
# The VPC, subnet and IAM role named below are reused when they exist.
# Whatever is missing is created by the CloudFormation stack, so deleting the
# stack removes only what it created:
#   aws cloudformation delete-stack --region <AWS_REGION> --stack-name <STACK_NAME>
#
# Usage: ./deploy.sh
#   Prints the plan and the change set, then asks before applying it.
#   Running it again updates the stack. Changes that replace the instance
#   (and delete its root volume) are called out before the prompt.

# ================================ settings ================================
export AWS_REGION="ap-northeast-2"
export STACK_NAME="ec2-ssh-remote"            # one stack per instance

export INSTANCE_NAME="ec2-ssh-remote"         # Name tag
export INSTANCE_TYPE="m8g.xlarge"             # the AL2023 AMI is picked for its CPU architecture
export VOLUME_SIZE="40"                       # root gp3 volume, GiB

export VPC_NAME="ec2-ssh-remote-vpc"          # found by Name tag; created if missing
export VPC_CIDR="10.0.0.0/16"                 # used only when the VPC is created
export SUBNET_NAME="ec2-ssh-remote-private"   # found by Name tag in the VPC; created with NAT egress if missing
export AVAILABILITY_ZONE=""                   # used only when the subnet is created; empty = first AZ offering INSTANCE_TYPE

export ROLE_NAME="ec2-ssh-remote-role"        # reused if it exists, otherwise created with
                                              # AmazonSSMManagedInstanceCore, AWSCodeCommitPowerUser, AmazonS3FullAccess

# Settings for user-data.sh (runs once, at the first boot). They are written
# as NAME=value lines right after its shebang. To add one: export it here and
# add NAME="${NAME:?}" to the settings block of user-data.sh.
export TARGET_USER="ec2-user"
export NODE_MAJOR="22"                        # AL2023 provides 20, 22, 24
export PYTHON_VER="3.14"                      # AL2023 provides 3.11 - 3.14
export SWAP_SIZE_MB="2048"                    # 0 disables swap
export INSTALL_DOCKER="false"
export INSTALL_P10K="true"                    # powerlevel10k prompt
export GIT_USER_NAME="YOUR-NAME"              # empty = skip git config
export GIT_USER_EMAIL="YOUR-EMAIL"
# ==========================================================================

set -euo pipefail

export AWS_DEFAULT_REGION="$AWS_REGION"   # AWS CLI v1 reads only this one
export AWS_PAGER=""                       # keep CLI v2 from opening a pager

# shellcheck disable=SC2034  # used by the @embed functions only when run from src/
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLACEHOLDER='{{USER_DATA_BASE64}}'
USER_DATA_MAX_BYTES=16384       # EC2 limit, before base64
TEMPLATE_BODY_MAX_BYTES=51200   # CloudFormation limit for --template-body

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
row()  { printf '  %-12s %s\n' "$1" "$2"; }
# shellcheck disable=SC2086  # unquoted on purpose: collapses tabs/newlines into single spaces
words() { echo $1; }

# aws ... --output text, with JMESPath null ("None") mapped to "".
awsq() {
  local out
  out="$(aws "$@" --output text)" || return 1
  if [[ "$out" == "None" ]]; then out=""; fi
  printf '%s' "$out"
}

# awsq with the output collapsed into one space-separated line.
awsw() {
  local out
  out="$(awsq "$@")" || return 1
  words "$out"
}

# Functions below that run inside $(...) return 1 on a failed aws call
# explicitly: bash does not apply set -e inside command substitutions.

# Prints the single ID found, or nothing. Dies when more than one matches.
one_id() {
  local what="$1" ids
  shift
  ids="$(awsw "$@")" || return 1
  if [[ "$ids" == *" "* ]]; then die "more than one $what: $ids"; fi
  printf '%s' "$ids"
}

# ------------------------------------------------------------- CIDR math
ip2int() { local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
is_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }

# First free block inside CIDR $1 that overlaps none of the CIDRs in $2
# (space separated). Tries /24 first, then smaller blocks down to /28.
free_subnet() {
  local len="${1#*/}" start end size prefix n cidr u_len u_start clash
  start=$(( $(ip2int "${1%/*}") & ~((1 << (32 - len)) - 1) ))
  end=$(( start + (1 << (32 - len)) ))
  for (( prefix = (len > 24 ? len : 24); prefix <= 28; prefix++ )); do
    size=$(( 1 << (32 - prefix) ))
    for (( n = start; n < end; n += size )); do
      clash=0
      # shellcheck disable=SC2086  # $2 is a space-separated list
      for cidr in $2; do
        u_len="${cidr#*/}"
        u_start=$(( $(ip2int "${cidr%/*}") & ~((1 << (32 - u_len)) - 1) ))
        if (( n < u_start + (1 << (32 - u_len)) && u_start < n + size )); then clash=1; break; fi
      done
      if (( clash == 0 )); then echo "$(int2ip "$n")/$prefix"; return 0; fi
    done
  done
  return 1
}

# ------------------------------------------------------- CloudFormation
stack_status() {
  local out
  if out="$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
              --query 'Stacks[0].StackStatus' --output text 2>&1)"; then
    printf '%s' "$out"
  elif [[ "$out" == *"does not exist"* ]]; then
    printf 'NONE'
  else
    die "describe-stacks failed: $out"
  fi
}

stack_has_resources() { [[ "$STACK_STATUS" != NONE && "$STACK_STATUS" != REVIEW_IN_PROGRESS ]]; }

# Physical ID of a resource this stack manages, by logical ID. Resources the
# stack manages stay in "create" mode so an update does not delete them.
owned() {
  printf '%s\n' "$STACK_RESOURCES" | awk -v id="$1" '$1 == id { print $2 }'
}

stack_param() {
  if stack_has_resources; then
    awsq cloudformation describe-stacks --stack-name "$STACK_NAME" \
      --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue | [0]"
  fi
}

# Deletes the empty REVIEW_IN_PROGRESS stack left by an unused CREATE change set.
drop_review_stack() {
  if [[ "$CS_TYPE" == CREATE && "$(stack_status)" == REVIEW_IN_PROGRESS ]]; then
    aws cloudformation delete-stack --stack-name "$STACK_NAME"
  fi
}

show_outputs() {
  local id
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
  id="$(awsq cloudformation describe-stacks --stack-name "$STACK_NAME" \
          --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue | [0]")"
  echo
  echo "SSM Agent registers 1-2 minutes after boot. Then:"
  echo "  shell: aws ssm start-session --region $AWS_REGION --target $id"
  echo "  ssh:   ssh $id   (needs the ~/.ssh/config entry from README.md)"
}

# ------------------------------------------------------------ EC2 / IAM
subnet_info() {   # -> "vpc-id cidr az"
  awsq ec2 describe-subnets --subnet-ids "$1" --query 'Subnets[0].[VpcId,CidrBlock,AvailabilityZone]'
}

vpc_subnet_cidrs() {
  awsw ec2 describe-subnets --filters "Name=vpc-id,Values=$1" --query 'Subnets[].CidrBlock'
}

# Target of the 0.0.0.0/0 route of a subnet (explicit or main route table).
default_route_target() {
  local rt
  rt="$(awsq ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$1" \
          --query 'RouteTables[0].RouteTableId')" || return 1
  if [[ -z "$rt" ]]; then
    rt="$(awsq ec2 describe-route-tables --filters "Name=vpc-id,Values=$2" Name=association.main,Values=true \
            --query 'RouteTables[0].RouteTableId')" || return 1
  fi
  awsq ec2 describe-route-tables --route-table-ids "$rt" --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'] | [0].[NatGatewayId || GatewayId || TransitGatewayId || NetworkInterfaceId || VpcPeeringConnectionId]"
}

# Standard AZs of the region that offer the instance type, sorted.
azs_offering() {
  local offered zones z
  offered=" $(awsw ec2 describe-instance-type-offerings --location-type availability-zone \
               --filters "Name=instance-type,Values=$1" --query 'InstanceTypeOfferings[].Location') " || return 1
  zones="$(awsq ec2 describe-availability-zones \
             --filters Name=zone-type,Values=availability-zone Name=state,Values=available \
             --query 'AvailabilityZones[].ZoneName')" || return 1
  # shellcheck disable=SC2086  # zones is a whitespace-separated list
  for z in $(printf '%s\n' $zones | sort); do
    if [[ "$offered" == *" $z "* ]]; then printf '%s ' "$z"; fi
  done
}

arch_for_type() {
  local archs
  archs=" $(awsw ec2 describe-instance-types --instance-types "$1" \
             --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures') " || return 1
  case "$archs" in
    *" arm64 "*)  echo arm64 ;;
    *" x86_64 "*) echo x86_64 ;;
    *) die "AL2023 has no AMI for $1 (architectures:$archs)" ;;
  esac
}

role_exists() {
  local out
  if out="$(aws iam get-role --role-name "$1" --query Role.Arn --output text 2>&1)"; then return 0; fi
  if [[ "$out" == *NoSuchEntity* ]]; then return 1; fi
  die "iam get-role failed: $out"
}

check_existing_role() {
  local trust policies
  trust="$(aws iam get-role --role-name "$1" --query Role.AssumeRolePolicyDocument --output json)"
  if [[ "$trust" != *ec2.amazonaws.com* ]]; then
    die "role $1 exists but its trust policy does not allow ec2.amazonaws.com"
  fi
  policies=" $(awsw iam list-attached-role-policies --role-name "$1" --query 'AttachedPolicies[].PolicyName') "
  if [[ "$policies" != *" AmazonSSMManagedInstanceCore "* ]]; then
    warn "role $1 has no AmazonSSMManagedInstanceCore attached; Session Manager needs those permissions"
  fi
}

# ------------------------------------------------------------- user data
# Writes the user data with NAME=value lines right after the shebang, one for
# every NAME="${NAME...}" line in its settings block. Records them in
# UD_SETTINGS for the plan.
UD_SETTINGS=""
render_user_data() {
  local body="$1" name line
  head -n 1 "$body"
  echo "# ---- settings from deploy.sh ----"
  # shellcheck disable=SC2013  # one variable name per line, no spaces
  for name in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)="\${\1[-:?].*/\1/p' "$body"); do
    declare -p "$name" >/dev/null 2>&1 ||
      die "the user data uses $name: add export $name=\"...\" to the settings at the top"
    line="$(printf '%s=%q' "$name" "${!name}")"
    echo "$line"
    UD_SETTINGS="$UD_SETTINGS$line"$'\n'
  done
  echo "# ---------------------------------"
  tail -n +2 "$body"
}

json_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

# KEY=value arguments -> CloudFormation parameters JSON.
params_json() {
  local kv sep=""
  printf '['
  for kv in "$@"; do
    printf '%s\n  {"ParameterKey": "%s", "ParameterValue": "%s"}' "$sep" "${kv%%=*}" "$(json_escape "${kv#*=}")"
    sep=","
  done
  printf '\n]\n'
}

# =================================================================== main
main() {
  command -v aws >/dev/null || die "AWS CLI is not installed"
  for v in AWS_REGION STACK_NAME INSTANCE_NAME INSTANCE_TYPE VPC_NAME SUBNET_NAME ROLE_NAME; do
    [[ -n "${!v}" ]] || die "$v is empty"
  done
  [[ "$VOLUME_SIZE" =~ ^[0-9]+$ ]] || die "VOLUME_SIZE must be a number of GiB: $VOLUME_SIZE"
  is_cidr "$VPC_CIDR" || die "VPC_CIDR is not a CIDR: $VPC_CIDR"

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  template > "$TMP/template.raw"
  grep -qF "$PLACEHOLDER" "$TMP/template.raw" || die "the template has no UserData placeholder $PLACEHOLDER"

  ACCOUNT="$(awsq sts get-caller-identity --query Account)"
  STACK_STATUS="$(stack_status)"
  case "$STACK_STATUS" in
    NONE|REVIEW_IN_PROGRESS) CS_TYPE=CREATE ;;
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE|IMPORT_ROLLBACK_COMPLETE) CS_TYPE=UPDATE ;;
    ROLLBACK_COMPLETE)
      die "stack $STACK_NAME failed to create and holds no resources. Delete it, then run again:
    aws cloudformation delete-stack --region $AWS_REGION --stack-name $STACK_NAME" ;;
    *_IN_PROGRESS) die "stack $STACK_NAME is busy ($STACK_STATUS); run again when it finishes" ;;
    *) die "stack $STACK_NAME is in $STACK_STATUS; resolve it in the CloudFormation console first" ;;
  esac

  STACK_RESOURCES=""
  if stack_has_resources; then
    # shellcheck disable=SC2016  # backticks are a JMESPath literal
    STACK_RESOURCES="$(awsq cloudformation list-stack-resources --stack-name "$STACK_NAME" \
      --query 'StackResourceSummaries[?ResourceStatus!=`DELETE_COMPLETE`].[LogicalResourceId,PhysicalResourceId]')"
  fi

  log "Looking up resources in account $ACCOUNT, $AWS_REGION ..."

  # ---- AMI: AL2023 for the instance type's architecture. On updates the
  # stack's current AMI is kept while the architecture matches, because a new
  # ImageId replaces the instance.
  ARCH="$(arch_for_type "$INSTANCE_TYPE")"
  prev_ami="$(stack_param ImageId)"
  prev_arch=""
  if [[ -n "$prev_ami" ]]; then
    prev_arch="$(awsq ec2 describe-images --image-ids "$prev_ami" --query 'Images[0].Architecture' 2>/dev/null || true)"
  fi
  if [[ -n "$prev_ami" && "$prev_arch" == "$ARCH" ]]; then
    IMAGE_ID="$prev_ami"
    AMI_NOTE="kept from the stack"
  else
    IMAGE_ID="$(awsq ssm get-parameter --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$ARCH" \
                  --query Parameter.Value)"
    AMI_NOTE="latest AL2023 $ARCH"
  fi
  AMI_NAME="$(awsq ec2 describe-images --image-ids "$IMAGE_ID" --query 'Images[0].Name')"

  # ---- IAM role
  own_role="$(owned InstanceRole)"
  if [[ -n "$own_role" && "$own_role" == "$ROLE_NAME" ]]; then
    CREATE_ROLE=true;  ROLE_NOTE="managed by this stack"
  elif role_exists "$ROLE_NAME"; then
    check_existing_role "$ROLE_NAME"
    CREATE_ROLE=false; ROLE_NOTE="reuse existing role"
  else
    CREATE_ROLE=true;  ROLE_NOTE="create (AmazonSSMManagedInstanceCore, AWSCodeCommitPowerUser, AmazonS3FullAccess)"
  fi

  # ---- VPC
  own_vpc="$(owned Vpc)"
  found_vpc="$(one_id "VPC named $VPC_NAME" ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query 'Vpcs[].VpcId')"
  if [[ -n "$found_vpc" && "$found_vpc" != "$own_vpc" ]]; then
    VPC_ID="$found_vpc"; TARGET_VPC="$found_vpc"
    STACK_VPC_CIDR="$VPC_CIDR"   # unused by the template in this case
    base_cidr="$(awsq ec2 describe-vpcs --vpc-ids "$found_vpc" --query 'Vpcs[0].CidrBlock')"
    VPC_NOTE="reuse $found_vpc ($base_cidr)"
  elif [[ -n "$own_vpc" ]]; then
    VPC_ID=""; TARGET_VPC="$own_vpc"
    STACK_VPC_CIDR="$(awsq ec2 describe-vpcs --vpc-ids "$own_vpc" --query 'Vpcs[0].CidrBlock')"
    base_cidr="$STACK_VPC_CIDR"
    VPC_NOTE="managed by this stack ($own_vpc, $STACK_VPC_CIDR)"
    if [[ "$STACK_VPC_CIDR" != "$VPC_CIDR" ]]; then
      warn "VPC_CIDR=$VPC_CIDR ignored: the stack's VPC already uses $STACK_VPC_CIDR"
    fi
  else
    VPC_ID=""; TARGET_VPC=""
    STACK_VPC_CIDR="$VPC_CIDR"; base_cidr="$VPC_CIDR"
    len="${VPC_CIDR#*/}"
    if (( len < 16 || len > 27 )); then die "VPC_CIDR must be /16 to /27 (it holds two subnets): $VPC_CIDR"; fi
    VPC_NOTE="create ($VPC_CIDR)"
  fi
  used_cidrs=""
  if [[ -n "$TARGET_VPC" ]]; then used_cidrs="$(vpc_subnet_cidrs "$TARGET_VPC")"; fi

  # ---- private subnet
  AZS="$(azs_offering "$INSTANCE_TYPE")"
  [[ -n "$AZS" ]] || die "no Availability Zone in $AWS_REGION offers $INSTANCE_TYPE"
  own_subnet="$(owned PrivateSubnet)"
  found_subnet=""
  if [[ -n "$TARGET_VPC" ]]; then
    found_subnet="$(one_id "subnet named $SUBNET_NAME in $TARGET_VPC" ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$TARGET_VPC" "Name=tag:Name,Values=$SUBNET_NAME" --query 'Subnets[].SubnetId')"
  fi
  own_subnet_vpc=""
  if [[ -n "$own_subnet" ]]; then
    info="$(subnet_info "$own_subnet")"
    read -r own_subnet_vpc own_subnet_cidr own_subnet_az <<<"$info"
  fi

  if [[ -n "$found_subnet" && "$found_subnet" != "$own_subnet" ]]; then
    SUBNET_ID="$found_subnet"
    info="$(subnet_info "$found_subnet")"
    read -r _vpc PRIVATE_CIDR AZ <<<"$info"
    SUBNET_NOTE="reuse $found_subnet ($PRIVATE_CIDR, $AZ)"
    target="$(default_route_target "$found_subnet" "$TARGET_VPC")"
    case "$target" in
      nat-*) ;;
      igw-*) warn "subnet $SUBNET_NAME routes 0.0.0.0/0 to $target (public subnet). The instance gets no public IP, so it reaches SSM only through VPC endpoints." ;;
      "")    warn "subnet $SUBNET_NAME has no 0.0.0.0/0 route. The instance reaches SSM only through VPC endpoints." ;;
      *)     log "Note: subnet $SUBNET_NAME routes 0.0.0.0/0 to $target." ;;
    esac
  else
    SUBNET_ID=""
    if [[ -n "$own_subnet" && "$own_subnet_vpc" == "$TARGET_VPC" ]]; then
      PRIVATE_CIDR="$own_subnet_cidr"; AZ="$own_subnet_az"
      SUBNET_NOTE="managed by this stack ($own_subnet, $PRIVATE_CIDR, $AZ)"
      if [[ -n "$AVAILABILITY_ZONE" && "$AVAILABILITY_ZONE" != "$AZ" ]]; then
        warn "AVAILABILITY_ZONE=$AVAILABILITY_ZONE ignored: the stack's subnet is in $AZ"
      fi
    else
      AZ="${AVAILABILITY_ZONE:-${AZS%% *}}"
      PRIVATE_CIDR="$(free_subnet "$base_cidr" "$used_cidrs")" || die "no free /24-/28 block left in $base_cidr for the subnet"
      used_cidrs="$used_cidrs $PRIVATE_CIDR"
      SUBNET_NOTE="create ($PRIVATE_CIDR, $AZ)"
    fi
  fi
  if [[ " $AZS" != *" $AZ "* ]]; then die "$INSTANCE_TYPE is not offered in $AZ. AZs that offer it: $AZS"; fi

  # ---- NAT gateway and internet gateway (only for a subnet this stack creates)
  NAT_ID=""; IGW_ID=""; PUBLIC_CIDR=""
  NAT_NOTE="not managed (existing subnet)"; IGW_NOTE="$NAT_NOTE"
  if [[ -z "$SUBNET_ID" ]]; then
    own_nat="$(owned NatGateway)"
    if [[ -n "$VPC_ID" && -z "$own_nat" ]]; then
      NAT_ID="$(awsq ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC_ID" Name=state,Values=available \
                  --query "NatGateways[?ConnectivityType=='public'] | [0].NatGatewayId")"
    fi
    if [[ -n "$NAT_ID" ]]; then
      NAT_NOTE="reuse $NAT_ID"; IGW_NOTE="not needed (reusing a NAT gateway)"
    else
      own_public="$(owned PublicSubnet)"
      own_public_vpc=""
      if [[ -n "$own_public" ]]; then
        info="$(subnet_info "$own_public")"
        read -r own_public_vpc own_public_cidr _az <<<"$info"
      fi
      if [[ -n "$own_public" && "$own_public_vpc" == "$TARGET_VPC" ]]; then
        PUBLIC_CIDR="$own_public_cidr"
        NAT_NOTE="managed by this stack ($(owned NatGateway), public subnet $PUBLIC_CIDR)"
      else
        PUBLIC_CIDR="$(free_subnet "$base_cidr" "$used_cidrs")" || die "no free /24-/28 block left in $base_cidr for the NAT gateway's public subnet"
        NAT_NOTE="create (public subnet $PUBLIC_CIDR, $AZ)"
      fi
      own_igw="$(owned InternetGateway)"
      if [[ -n "$VPC_ID" && -z "$own_igw" ]]; then
        IGW_ID="$(awsq ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
                    --query 'InternetGateways[0].InternetGatewayId')"
      fi
      if [[ -n "$IGW_ID" ]]; then IGW_NOTE="reuse $IGW_ID"
      elif [[ -n "$own_igw" ]]; then IGW_NOTE="managed by this stack ($own_igw)"
      else IGW_NOTE="create"
      fi
    fi
  fi

  # ---- template with user data
  user_data > "$TMP/user-data.body"
  render_user_data "$TMP/user-data.body" > "$TMP/user-data"
  ud_payload="$TMP/user-data"
  ud_bytes=$(( $(wc -c < "$ud_payload") ))
  UD_NOTE="user-data.sh ($ud_bytes bytes)"
  if (( ud_bytes > USER_DATA_MAX_BYTES )); then
    # cloud-init decompresses gzip user data before running it.
    gzip -9 -n -c "$TMP/user-data" > "$TMP/user-data.gz"
    ud_payload="$TMP/user-data.gz"
    gz_bytes=$(( $(wc -c < "$ud_payload") ))
    (( gz_bytes <= USER_DATA_MAX_BYTES )) ||
      die "user data is $ud_bytes bytes ($gz_bytes gzipped); EC2 allows $USER_DATA_MAX_BYTES"
    UD_NOTE="user-data.sh ($ud_bytes bytes, sent gzipped: $gz_bytes bytes; EC2 limit $USER_DATA_MAX_BYTES)"
  fi
  ud_b64="$(base64 < "$ud_payload" | tr -d '\n')"
  sed "s|$PLACEHOLDER|$ud_b64|" "$TMP/template.raw" > "$TMP/template.yaml"
  tpl_bytes=$(( $(wc -c < "$TMP/template.yaml") ))
  (( tpl_bytes <= TEMPLATE_BODY_MAX_BYTES )) || die "rendered template is $tpl_bytes bytes; --template-body allows $TEMPLATE_BODY_MAX_BYTES"

  params_json \
    "InstanceName=$INSTANCE_NAME" "InstanceType=$INSTANCE_TYPE" "VolumeSize=$VOLUME_SIZE" "ImageId=$IMAGE_ID" \
    "RoleName=$ROLE_NAME" "CreateRole=$CREATE_ROLE" \
    "VpcId=$VPC_ID" "VpcName=$VPC_NAME" "VpcCidr=$STACK_VPC_CIDR" \
    "SubnetId=$SUBNET_ID" "SubnetName=$SUBNET_NAME" "PrivateSubnetCidr=$PRIVATE_CIDR" "PublicSubnetCidr=$PUBLIC_CIDR" \
    "AvailabilityZone=$AZ" "NatGatewayId=$NAT_ID" "InternetGatewayId=$IGW_ID" \
    > "$TMP/params.json"

  # ---- plan
  echo
  echo "Plan"
  row "Account"     "$ACCOUNT ($AWS_REGION)"
  if [[ "$CS_TYPE" == CREATE ]]; then row "Stack" "$STACK_NAME (new)"; else row "Stack" "$STACK_NAME (update, $STACK_STATUS)"; fi
  row "Instance"    "$INSTANCE_NAME  $INSTANCE_TYPE ($ARCH)  gp3 ${VOLUME_SIZE} GiB"
  row "AMI"         "$IMAGE_ID $AMI_NAME ($AMI_NOTE)"
  row "IAM role"    "$ROLE_NAME: $ROLE_NOTE"
  row "VPC"         "$VPC_NAME: $VPC_NOTE"
  row "Subnet"      "$SUBNET_NAME: $SUBNET_NOTE"
  row "NAT gateway" "$NAT_NOTE"
  row "Internet gw" "$IGW_NOTE"
  row "User data"   "$UD_NOTE"
  printf '%s' "$UD_SETTINGS" | sed 's/^/                 /'
  echo

  # ---- change set
  CS_NAME="deploy-$(date +%Y%m%d-%H%M%S)"
  log "Creating change set $CS_NAME ..."
  aws cloudformation create-change-set \
    --stack-name "$STACK_NAME" --change-set-name "$CS_NAME" --change-set-type "$CS_TYPE" \
    --template-body "file://$TMP/template.yaml" --parameters "file://$TMP/params.json" \
    --capabilities CAPABILITY_NAMED_IAM >/dev/null
  cs=(--stack-name "$STACK_NAME" --change-set-name "$CS_NAME")

  if ! aws cloudformation wait change-set-create-complete "${cs[@]}" 2>/dev/null; then
    reason="$(awsq cloudformation describe-change-set "${cs[@]}" --query StatusReason)"
    aws cloudformation delete-change-set "${cs[@]}" >/dev/null 2>&1 || true
    if [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates are to be performed"* ]]; then
      log "No changes: the stack already matches these settings."
      show_outputs
      exit 0
    fi
    drop_review_stack
    die "change set failed: $reason"
  fi

  aws cloudformation describe-change-set "${cs[@]}" \
    --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' --output table
  replaced="$(awsw cloudformation describe-change-set "${cs[@]}" \
    --query "Changes[?ResourceChange.Action=='Modify' && ResourceChange.Replacement!='False'].ResourceChange.LogicalResourceId")"
  removed="$(awsw cloudformation describe-change-set "${cs[@]}" \
    --query "Changes[?ResourceChange.Action=='Remove'].ResourceChange.LogicalResourceId")"
  instance_props=" $(awsw cloudformation describe-change-set "${cs[@]}" \
    --query "Changes[?ResourceChange.LogicalResourceId=='Instance'].ResourceChange.Details[].Target.Name") "

  if [[ " $replaced " == *" Instance "* ]]; then
    warn "The instance will be REPLACED: the current one is terminated and its root volume deleted."
  elif [[ "$instance_props" == *" UserData "* ]]; then
    warn "User data changed: the instance will be stopped and started, and the new user data will NOT run."
  fi
  if [[ -n "$replaced" ]]; then warn "Replaced: $replaced"; fi
  if [[ -n "$removed" ]];  then warn "Deleted:  $removed"; fi

  answer=""
  read -r -p "Apply change set $CS_NAME to $STACK_NAME? [y/N] " answer || true
  case "$answer" in
    y|Y|yes|YES) ;;
    *)
      aws cloudformation delete-change-set "${cs[@]}" >/dev/null || true
      drop_review_stack
      die "aborted; nothing was changed" ;;
  esac

  aws cloudformation execute-change-set "${cs[@]}"
  if [[ "$CS_TYPE" == CREATE ]]; then waiter=stack-create-complete; else waiter=stack-update-complete; fi
  log "Waiting for $waiter ..."
  if ! aws cloudformation wait "$waiter" --stack-name "$STACK_NAME"; then
    aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --max-items 40 \
      --query "StackEvents[?ends_with(ResourceStatus, 'FAILED')].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
      --output table >&2 || true
    die "stack $STACK_NAME failed; status is now $(stack_status)"
  fi
  show_outputs
}

# ================================================================ EMBEDDED
# scripts/build.sh replaces each function marked "@embed <file>" with one that prints
# the file from a heredoc, so dist/deploy.sh runs on its own. Run from src/,
# these read the files next to this script.
template()  { cat "$SRC_DIR/ec2-ssh-remote.yaml"; }  # @embed ec2-ssh-remote.yaml
user_data() { cat "$SRC_DIR/user-data.sh"; }         # @embed user-data.sh

main "$@"
