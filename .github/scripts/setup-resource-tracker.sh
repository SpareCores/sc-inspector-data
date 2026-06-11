#!/usr/bin/env bash
# Fetch Sentinel API token from SSM and install resource-tracker.
# Requires AWS credentials (configure-aws-credentials) in the environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v aws >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y awscli
fi

SENTINEL_API_TOKEN="$(aws ssm get-parameter \
  --name "/sentinel/api-tokens/public-benchmarks" \
  --with-decryption \
  --region us-east-1 \
  --query 'Parameter.Value' \
  --output text)"
echo "::add-mask::$SENTINEL_API_TOKEN"
echo "SENTINEL_API_TOKEN=$SENTINEL_API_TOKEN" >> "$GITHUB_ENV"

bash "${SCRIPT_DIR}/install-resource-tracker.sh"
