#!/usr/bin/env bash
# Launch one benchmark run on a Graviton instance from the COOL Marketplace AMI,
# wait for it to finish and self-terminate, then save its console output.
#
# usage: infra/launch.sh [user-data script] [instance type]
#   e.g. infra/launch.sh infra/run-userdata.sh c8g.large
#
# Needs the AWS CLI configured (AWS_PROFILE / AWS_REGION are honoured) and a one-time
# Marketplace subscription to COOL accepted in the console.
set -euo pipefail

USERDATA="${1:-infra/run-userdata.sh}"
TYPE="${2:-c8g.large}"
REGION="${AWS_REGION:-us-east-1}"
AMI="${COOL_AMI:-ami-033e481a24f94c8cb}"   # COOL AMI in us-east-1
MAX_MINUTES="${MAX_MINUTES:-60}"
OUT_DIR="benchmarks/raw"
mkdir -p "$OUT_DIR"

# The instance terminates itself (shutdown -h now + shutdown behavior "terminate").
# No key pair and no ingress rules: results come back through the console log.
ID=$(aws ec2 run-instances \
  --region "$REGION" \
  --image-id "$AMI" \
  --instance-type "$TYPE" \
  --count 1 \
  --user-data "file://$USERDATA" \
  --instance-initiated-shutdown-behavior terminate \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=cool-auto-tuner},{Key=Project,Value=opencv-cool-optimizer}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "launched $ID ($TYPE, $REGION)"

# Hard backstop: terminate it ourselves if it outlives MAX_MINUTES.
cleanup() {
  state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)
  if [ "$state" != "terminated" ] && [ "$state" != "shutting-down" ]; then
    echo "terminating $ID (state: $state)"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$ID" >/dev/null
  fi
}
trap cleanup EXIT

deadline=$(( $(date +%s) + MAX_MINUTES * 60 ))
while :; do
  state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)
  echo "$(date +%H:%M:%S) $state"
  case "$state" in shutting-down|terminated) break ;; esac
  if [ "$(date +%s)" -ge "$deadline" ]; then echo "timed out after ${MAX_MINUTES}m"; break; fi
  sleep 30
done

# The console log stays readable for a while after termination.
out="$OUT_DIR/${ID}_$(basename "$USERDATA" .sh).log"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  aws ec2 get-console-output --region "$REGION" --instance-id "$ID" --latest \
    --query Output --output text > "$out" 2>/dev/null || true
  [ -s "$out" ] && [ "$(cat "$out")" != "None" ] && break
  sleep 30
done
echo "console output saved to $out"
grep -E "TARGET_MET|TARGET_NOT_MET|speedup" "$out" | tail -20 || true
