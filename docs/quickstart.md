# Quickstart — 30 minutes from empty AWS account to first ECS run

## Prerequisites

- AWS CLI v2 with admin-level credentials (first-time setup needs IAM / CloudFormation perms)
- Docker Desktop with `buildx` plugin
- An existing ECS cluster (Fargate-capable) — see [Creating a cluster](#creating-a-cluster) if you don't have one

## 1. Infra (5 min)

Deploy the CloudFormation stack — it creates **all** AWS resources in one go
(ECR repo, S3 bucket, CloudFront distribution, CloudWatch log group, IAM roles):

```bash
# Pick a unique bucket name (must be globally unique in S3)
BUCKET="acme-api-reports-${RANDOM}"

aws cloudformation deploy \
  --stack-name pytest-api-kit-infra \
  --template-file templates/cloudformation/infra.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ProjectName=acme-api-tests \
      ReportBucketName="$BUCKET"
```

Grab the outputs:

```bash
aws cloudformation describe-stacks --stack-name pytest-api-kit-infra \
  --query "Stacks[0].Outputs" --output table
```

Note the **CloudFrontDomain** and **EcrRepoUri** — you'll need them.

## 2. Secrets (5 min)

Store sensitive env vars in AWS Secrets Manager:

```bash
aws secretsmanager create-secret \
  --name pytest-api-kit/uat \
  --secret-string '{
    "API_PASSWORD": "...",
    "SLACK_WEBHOOK_URL": "https://hooks.slack.com/services/..."
  }'
```

The ECS task already has `secretsmanager:GetSecretValue` via the task role
created by CloudFormation.

## 3. First deploy (5 min)

Copy `templates/scripts/*` and `templates/docker/Dockerfile` into your project
repo (alongside your `tests/`, `pytest.ini`, `requirements.txt`):

```bash
cp templates/scripts/*.sh /path/to/your-tests/scripts/
cp templates/scripts/*.py /path/to/your-tests/scripts/
cp templates/docker/Dockerfile /path/to/your-tests/
chmod +x /path/to/your-tests/scripts/*.sh
```

Set the env vars `deploy_ecs.sh` needs (add to `.envrc` or a `.env` file):

```bash
export ECS_CLUSTER=acme-cluster
export S3_BUCKET=acme-api-reports-12345
export FARGATE_SUBNET=subnet-0abc...
export FARGATE_SG=sg-0xyz...
export ECR_REPO=acme-api-tests  # matches CloudFormation ProjectName
export TASK_FAMILY=acme-api-tests
export LOG_GROUP=/ecs/acme-api-tests
export SECRET_ARN=arn:aws:secretsmanager:ap-northeast-1:1234567890:secret:pytest-api-kit/uat-XXXXXX
```

Then:

```bash
cd /path/to/your-tests

# First time only — registers IAM roles + task definition
./scripts/deploy_ecs.sh setup

# Build + push docker image
./scripts/deploy_ecs.sh build

# Run a test
./scripts/deploy_ecs.sh run uat
```

## 4. View reports (instant)

Open the CloudFront domain in a browser:

```
https://d2xxxxxxxxx.cloudfront.net/
```

You'll see a dashboard listing runs grouped by environment, with links to each
`report.html`.

## 5. Daily CI (5 min)

Copy `templates/workflows/daily-smoke.yml` into `.github/workflows/` and set
these repo secrets:

- `AWS_ROLE_TO_ASSUME` — the OIDC role ARN (see [AWS OIDC trust policy](#aws-oidc-trust-policy))
- `FARGATE_SUBNET` — same as your `FARGATE_SUBNET` env var
- `FARGATE_SG` — same as your `FARGATE_SG`

Commit + push. The workflow runs daily at **UTC 22:47 / Taipei 06:47** (a deliberately
off-peak minute — GitHub drops scheduled workflows during high-traffic times).

## Creating a cluster

If you don't have an ECS cluster yet:

```bash
aws ecs create-cluster --cluster-name acme-cluster
```

Fargate tasks don't need you to provision nodes.

## AWS OIDC trust policy

For GitHub Actions to assume an AWS IAM role via OIDC (no long-lived keys):

1. In AWS console → IAM → Identity providers → Add provider
   - URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. Create an IAM role with this trust policy:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringLike": {
           "token.actions.githubusercontent.com:sub": "repo:<org>/<repo>:*"
         }
       }
     }]
   }
   ```
3. Attach a policy granting `ecs:RunTask`, `ecs:DescribeTasks`, `iam:PassRole`
   on the two task roles.

## Troubleshooting

### Task fails with `ResourceInitializationError: unable to pull secrets or registry auth`

Your task execution role probably can't reach ECR or Secrets Manager from the
private subnet. Check: (1) subnet has a NAT Gateway route to 0.0.0.0/0, or
(2) VPC endpoints for `com.amazonaws.<region>.ecr.dkr` + `com.amazonaws.<region>.ecr.api` + `com.amazonaws.<region>.secretsmanager` exist.

### `AccessDenied: s3:PutObject` when uploading report

Task role is missing S3 write — check CloudFormation output `TaskRoleArn`
and verify the `s3-and-cf` inline policy is attached.

### CloudFront shows old index.html

The task script issues `cloudfront create-invalidation` automatically. If you
deleted `CLOUDFRONT_DISTRIBUTION_ID` from env, the cache lives 24h by default.

### Schedule isn't firing

GitHub silently drops cron at peak minutes (:00, :15, :30, :45). Our template
uses UTC 22:47 for that reason. Don't change to `:00 0 * * *` "to keep it
neat" — you'll lose runs.
