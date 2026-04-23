#!/bin/bash
# ---------------------------------------------------------------------------
# One-click deploy pytest runner to ECS Fargate.
#   ./scripts/deploy_ecs.sh [setup|build|run|all]
#
# Prerequisites:
#   - AWS CLI v2 with credentials configured (aws configure)
#   - Docker with buildx plugin (multi-arch build)
#   - An ECS cluster already created (otherwise pass --cluster flag via env)
#   - AWS Secrets Manager entry with your test credentials (see docs/secrets.md)
# ---------------------------------------------------------------------------
set -euo pipefail

# ── Customize: copy .env.example → .env and edit (or export env vars) ──
REGION="${AWS_REGION:-ap-northeast-1}"
CLUSTER="${ECS_CLUSTER:?set ECS_CLUSTER env var or edit script}"
ECR_REPO="${ECR_REPO:-pytest-api-kit}"
TASK_FAMILY="${TASK_FAMILY:-pytest-api-kit}"
S3_BUCKET="${S3_BUCKET:?set S3_BUCKET env var or edit script}"
LOG_GROUP="${LOG_GROUP:-/ecs/pytest-api-kit}"
SECRET_ARN="${SECRET_ARN:-}"  # optional; if set, Task Definition reads secrets from it
SUBNET="${FARGATE_SUBNET:?set FARGATE_SUBNET}"
SECURITY_GROUP="${FARGATE_SG:?set FARGATE_SG}"

# Auto-detected
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

echo "=== pytest-api-kit — AWS ECS deploy ==="
echo "  Account: ${ACCOUNT_ID}"
echo "  Region:  ${REGION}"
echo "  Cluster: ${CLUSTER}"
echo "  Image:   ${ECR_URI}:latest"
echo ""

# ---------------------------------------------------------------------------
# setup: one-time AWS resource creation
# ---------------------------------------------------------------------------
setup() {
  echo ">>> [1/5] ECR repository"
  aws ecr create-repository \
    --repository-name "${ECR_REPO}" \
    --region "${REGION}" \
    --image-scanning-configuration scanOnPush=true \
    2>/dev/null && echo "    created" || echo "    already exists"

  echo ">>> [2/5] S3 bucket (reports + static hosting)"
  aws s3 mb "s3://${S3_BUCKET}" --region "${REGION}" \
    2>/dev/null && echo "    created" || echo "    already exists"

  aws s3 website "s3://${S3_BUCKET}" --index-document index.html
  aws s3api put-bucket-policy --bucket "${S3_BUCKET}" --policy "$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "PublicRead",
    "Effect": "Allow",
    "Principal": "*",
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
  }]
}
EOF
)"
  echo "    static website enabled"

  echo ">>> [3/5] CloudWatch log group"
  aws logs create-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region "${REGION}" \
    2>/dev/null && echo "    created" || echo "    already exists"

  echo ">>> [4/5] IAM roles"
  _create_iam_roles

  echo ">>> [5/5] ECS task definition"
  _register_task_definition

  echo ""
  echo "=== Setup done ==="
  echo "  Static report site: http://${S3_BUCKET}.s3-website-${REGION}.amazonaws.com"
  echo ""
  echo "Next:"
  echo "  1. (Optional) Put test secrets into AWS Secrets Manager — see docs/secrets.md"
  echo "  2. ./scripts/deploy_ecs.sh build   # push docker image"
  echo "  3. ./scripts/deploy_ecs.sh run     # launch first test task"
}

# ---------------------------------------------------------------------------
# build: docker buildx → ECR
# ---------------------------------------------------------------------------
build() {
  echo ">>> ECR login"
  aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin \
        "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

  echo ">>> docker buildx (linux/amd64, push)"
  docker buildx build --platform linux/amd64 -t "${ECR_URI}:latest" --push .

  echo ""
  echo "=== Image pushed: ${ECR_URI}:latest ==="
}

# ---------------------------------------------------------------------------
# run: launch a Fargate task
# ---------------------------------------------------------------------------
run() {
  local ENV="${1:-uat}"
  echo ">>> run-task [env=${ENV}]"

  TASK_ARN=$(aws ecs run-task \
    --cluster "${CLUSTER}" \
    --task-definition "${TASK_FAMILY}" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET}],securityGroups=[${SECURITY_GROUP}],assignPublicIp=DISABLED}" \
    --overrides "{\"containerOverrides\":[{\"name\":\"pytest-runner\",\"environment\":[{\"name\":\"ENVIRONMENT\",\"value\":\"${ENV}\"}]}]}" \
    --query "tasks[0].taskArn" --output text \
    --region "${REGION}")

  echo ""
  echo "=== Task launched ==="
  echo "  Task ARN: ${TASK_ARN}"
  echo ""
  echo "Follow logs:"
  echo "  aws logs tail ${LOG_GROUP} --follow --region ${REGION}"
  echo "View reports:"
  echo "  http://${S3_BUCKET}.s3-website-${REGION}.amazonaws.com"
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_create_iam_roles() {
  local EXEC_ROLE="ecsTaskExecutionRole-${ECR_REPO}"
  local TASK_ROLE="ecsTaskRole-${ECR_REPO}"

  aws iam create-role \
    --role-name "${EXEC_ROLE}" \
    --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    2>/dev/null && echo "    created ${EXEC_ROLE}" || echo "    ${EXEC_ROLE} exists"

  aws iam attach-role-policy --role-name "${EXEC_ROLE}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy \
    2>/dev/null || true
  aws iam attach-role-policy --role-name "${EXEC_ROLE}" \
    --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \
    2>/dev/null || true

  aws iam create-role \
    --role-name "${TASK_ROLE}" \
    --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    2>/dev/null && echo "    created ${TASK_ROLE}" || echo "    ${TASK_ROLE} exists"

  # Task role: write S3 (for report upload), read Secrets Manager
  aws iam attach-role-policy --role-name "${TASK_ROLE}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true
  if [ -n "${SECRET_ARN}" ]; then
    aws iam attach-role-policy --role-name "${TASK_ROLE}" \
      --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite 2>/dev/null || true
  fi

  echo "    IAM roles ready"
}

_register_task_definition() {
  local EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole-${ECR_REPO}"
  local TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskRole-${ECR_REPO}"

  # Basic env vars — add yours by exporting `EXTRA_ENV_JSON` before calling setup
  local ENV_JSON='[
    {"name": "ECS_MODE",    "value": "1"},
    {"name": "ENVIRONMENT", "value": "uat"},
    {"name": "S3_BUCKET",   "value": "'"${S3_BUCKET}"'"}
  ]'

  # If SECRET_ARN was provided, wire commonly used keys from it.
  # Customise per your project's secret shape.
  local SECRETS_JSON='[]'
  if [ -n "${SECRET_ARN}" ]; then
    SECRETS_JSON='[
      {"name": "API_PASSWORD",        "valueFrom": "'"${SECRET_ARN}"':API_PASSWORD::"},
      {"name": "SLACK_WEBHOOK_URL",  "valueFrom": "'"${SECRET_ARN}"':SLACK_WEBHOOK_URL::"}
    ]'
  fi

  aws ecs register-task-definition \
    --family "${TASK_FAMILY}" \
    --requires-compatibilities FARGATE \
    --network-mode awsvpc \
    --cpu 512 --memory 1024 \
    --execution-role-arn "${EXEC_ROLE_ARN}" \
    --task-role-arn "${TASK_ROLE_ARN}" \
    --container-definitions "[{
      \"name\": \"pytest-runner\",
      \"image\": \"${ECR_URI}:latest\",
      \"essential\": true,
      \"environment\": ${ENV_JSON},
      \"secrets\": ${SECRETS_JSON},
      \"logConfiguration\": {
        \"logDriver\": \"awslogs\",
        \"options\": {
          \"awslogs-group\": \"${LOG_GROUP}\",
          \"awslogs-region\": \"${REGION}\",
          \"awslogs-stream-prefix\": \"pytest\"
        }
      }
    }]" \
    --region "${REGION}" > /dev/null

  echo "    task definition registered: ${TASK_FAMILY}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
case "${1:-help}" in
  setup) setup ;;
  build) build ;;
  run)   run "${2:-uat}" ;;
  all)
    setup
    echo ""
    build
    echo ""
    run "${2:-uat}"
    ;;
  *)
    echo "Usage: $0 {setup|build|run|all} [environment]"
    echo ""
    echo "  setup  - create AWS resources (ECR, S3, IAM, task definition)"
    echo "  build  - docker buildx + push to ECR"
    echo "  run    - launch Fargate task (default env: uat)"
    echo "  all    - everything in order"
    echo ""
    echo "Required env vars:"
    echo "  ECS_CLUSTER, S3_BUCKET, FARGATE_SUBNET, FARGATE_SG"
    echo "Optional env vars:"
    echo "  AWS_REGION (default ap-northeast-1)"
    echo "  ECR_REPO / TASK_FAMILY / LOG_GROUP (defaults shown in script)"
    echo "  SECRET_ARN (to wire AWS Secrets Manager into task env)"
    ;;
esac
