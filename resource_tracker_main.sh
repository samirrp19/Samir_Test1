#!/usr/bin/env bash
set -euo pipefail

## Author: Samir Prusty
## Date: 6th Feb 2026
## Version: v4
## Description:
##   Generates AWS resource report:
##   - EC2: filtered by multiple OwnerIds, only loops regions where those OwnerIds exist
##   - S3: global bucket list
##   - Lambda: all regions
##   - IAM: global user list
##   Outputs:
##   - Raw text report:   aws_resource_report_<TS>.txt
##   - Pretty text report:aws_resource_report_<TS>_pretty.txt
##   - Excel-friendly:    aws_resource_report_<TS>.xls  (TSV content; opens in Excel)
##   Also copies the .xls file to your OneDrive Desktop folder so you can open it in Excel.

# -----------------------------
# CONFIG
# -----------------------------
OWNER_IDS=("179968400330" "123456789012")  # <-- Add/remove OwnerIds here (Option 1)
EXCEL_DIR="/mnt/c/Users/Samir Prusty/OneDrive/Desktop/AWS_RESOURCE_TRACK"

# -----------------------------
# REMOVE OLDER REPORTS AND LOGS
# -----------------------------
cd /home/samrash/AWS
rm -f aws_resource_report_*.txt \
      aws_resource_report_*_pretty.txt \
      resource_tracker_cron.log \
      resource_tracker_cron_error.log \
      "$EXCEL_DIR"/aws_resource_report_*.xls

# -----------------------------
# OUTPUT NAMES
# -----------------------------
TS="$(date +%Y%m%d_%H%M%S)"
OUT="aws_resource_report_${TS}.txt"
PRETTY="aws_resource_report_${TS}_pretty.txt"
EXCEL_FILE="aws_resource_report_${TS}.xls"
EXCEL_PATH="${EXCEL_DIR}/${EXCEL_FILE}"

# -----------------------------
# HELPERS
# -----------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH"; exit 1; }; }
fmt_table() { command -v column >/dev/null 2>&1 && column -t -s $'\t' || cat; }
line() { printf '%*s\n' "${1:-120}" '' | tr ' ' '='; }
hdr() { echo; line 120; echo "$1"; line 120; }

aws_try() {
  # Best-effort AWS call; never exits the whole script if a single API call fails
  # Usage: aws_try aws <service> <op> ...
  local out
  if ! out="$("$@" 2>&1)"; then
    echo "AWS_ERROR: $*"
    echo "DETAIL: $out"
    return 1
  fi
  echo "$out"
  return 0
}

# -----------------------------
# PRECHECKS
# -----------------------------
need_cmd aws
need_cmd jq

# Convert bash array -> JSON array for jq filtering
OWNER_IDS_JSON="$(printf '%s\n' "${OWNER_IDS[@]}" | jq -R . | jq -s .)"

# -----------------------------
# HEADER
# -----------------------------
{
  echo "AWS Resource Report"
  echo "Generated: $(date)"
  echo "EC2 OwnerIds filter: ${OWNER_IDS[*]}"
  echo -n "Caller: "
  aws sts get-caller-identity --output json | jq -r '"\(.Arn) (Account: \(.Account))"' 2>/dev/null || echo "Unknown (no sts permission)"
} > "$OUT"

# -----------------------------
# REGIONS
# -----------------------------
REGIONS="$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null | tr '\t' '\n' | sort || true)"
if [[ -z "${REGIONS:-}" ]]; then
  echo "ERROR: Could not list regions. Check AWS CLI credentials/permissions." >&2
  exit 1
fi

# =========================================================
# EC2 - Instances (Filtered by OwnerIds; Region auto-skip)
# =========================================================
hdr "EC2 - Instances (Filtered by OwnerIds: ${OWNER_IDS[*]})" >> "$OUT"
{
  echo -e "Region\tOwnerId\tInstanceId\tName\tState\tType\tPublicDNS\tPublicIP\tPrivateIP\tVPC\tSubnet\tAZ\tSecurityGroups\tEBS_VolumeIds\tLaunchTime"
} >> "$OUT"

for r in $REGIONS; do
  json="$(aws_try aws ec2 describe-instances --region "$r" --output json || true)"
  [[ -z "${json:-}" ]] && continue
  [[ "${json:-}" == AWS_ERROR:* ]] && continue

  # Skip region if no matching OwnerId reservations
  has_owner="$(echo "$json" | jq -r --argjson oids "$OWNER_IDS_JSON" '
    [ .Reservations[]? | select(.OwnerId as $oid | $oids | index($oid)) ] | length
  ' 2>/dev/null || echo "0")"

  [[ "$has_owner" -eq 0 ]] && continue

  echo "$json" | jq -r --arg region "$r" --argjson oids "$OWNER_IDS_JSON" '
    .Reservations[]?
    | select(.OwnerId as $oid | $oids | index($oid))
    | (.OwnerId // "NA") as $owner
    | .Instances[]?
    | [
        $region,
        $owner,
        (.InstanceId // "NA"),
        ((.Tags // [] | map(select(.Key=="Name")) | .[0].Value) // "-"),
        (.State.Name // "NA"),
        (.InstanceType // "NA"),
        (.PublicDnsName // "-"),
        (.PublicIpAddress // "-"),
        (.PrivateIpAddress // "-"),
        (.VpcId // "-"),
        (.SubnetId // "-"),
        (.Placement.AvailabilityZone // "-"),
        ((.SecurityGroups // []) | map("\(.GroupName):\(.GroupId)") | join(",") | if .=="" then "-" else . end),
        ((.BlockDeviceMappings // []) | map(.Ebs.VolumeId // empty) | if length==0 then "-" else join(",") end),
        (.LaunchTime // "-")
      ] | @tsv
  ' 2>/dev/null >> "$OUT" || true
done

# =========================================================
# S3 - Buckets (Global)
# =========================================================
hdr "S3 - Buckets (Global)" >> "$OUT"
{
  echo -e "BucketName\tCreationDate"
} >> "$OUT"

s3json="$(aws_try aws s3api list-buckets --output json || true)"
if [[ -n "${s3json:-}" && "${s3json:-}" != AWS_ERROR:* ]]; then
  echo "$s3json" | jq -r '.Buckets[]? | [(.Name // "NA"), (.CreationDate // "-")] | @tsv' 2>/dev/null >> "$OUT" || true
else
  echo -e "ERROR\tUnable to list buckets (need s3:ListAllMyBuckets)" >> "$OUT"
fi

# =========================================================
# Lambda - Functions (All Regions)
# =========================================================
hdr "Lambda - Functions (All Regions)" >> "$OUT"
{
  echo -e "Region\tFunctionName\tRuntime\tMemoryMB\tTimeoutSec\tLastModified\tRole"
} >> "$OUT"

for r in $REGIONS; do
  ljson="$(aws_try aws lambda list-functions --region "$r" --output json || true)"
  [[ -z "${ljson:-}" ]] && continue
  [[ "${ljson:-}" == AWS_ERROR:* ]] && continue

  echo "$ljson" | jq -r --arg region "$r" '
    .Functions[]? |
    [
      $region,
      (.FunctionName // "NA"),
      (.Runtime // "-"),
      (.MemorySize // "-"),
      (.Timeout // "-"),
      (.LastModified // "-"),
      (.Role // "-")
    ] | @tsv
  ' 2>/dev/null >> "$OUT" || true
done

# =========================================================
# IAM - Users (Global)
# =========================================================
hdr "IAM - Users (Global)" >> "$OUT"
{
  echo -e "UserName\tUserId\tCreateDate\tArn"
} >> "$OUT"

ijson="$(aws_try aws iam list-users --output json || true)"
if [[ -n "${ijson:-}" && "${ijson:-}" != AWS_ERROR:* ]]; then
  echo "$ijson" | jq -r '.Users[]? | [(.UserName // "NA"), (.UserId // "-"), (.CreateDate // "-"), (.Arn // "-")] | @tsv' 2>/dev/null >> "$OUT" || true
else
  echo -e "ERROR\tUnable to list users (need iam:ListUsers)" >> "$OUT"
fi

# -----------------------------
# PRETTY TEXT REPORT (aligned)
# -----------------------------
cat "$OUT" | fmt_table > "$PRETTY"

# -----------------------------
# EXCEL-FRIENDLY .XLS (TSV content)
# -----------------------------
mkdir -p "$EXCEL_DIR"

# Keep headings + TSV rows; drop separator lines made of '=' only
# Excel will open this fine even though it is TSV content.
grep -vE '^[=]{3,}$' "$OUT" \
| sed '/^$/d' \
> "$EXCEL_PATH"

# -----------------------------
# SUMMARY
# -----------------------------
echo "Reports generated:"
echo "  Raw    : $(pwd)/$OUT"
echo "  Pretty : $(pwd)/$PRETTY"
echo "  Excel  : $EXCEL_PATH"

echo
echo "Open the OneDrive folder in Windows:"
echo "  explorer.exe \"${EXCEL_DIR}\""