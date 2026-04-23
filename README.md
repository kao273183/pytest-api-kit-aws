# pytest-api-kit-aws

> AWS Fargate deployment templates for `pytest-api-kit`.
> Clone, set env vars, run a script — your API smoke tests run daily on ECS with HTML reports hosted on CloudFront and a Slack notification when anything breaks.

**Companion repo to [`pytest-api-kit`](https://github.com/kao273183/pytest-api-kit)**
— not required but highly recommended.

---

## What you get

- 🐳 **Dockerfile** — minimal Python 3.11 + awscli + jq, ready for ECS Fargate
- 📦 **CloudFormation stack** — one-shot deploy of ECR + S3 + CloudFront + CloudWatch + IAM roles
- 🔧 **`deploy_ecs.sh`** — three-command workflow: `setup` (one-time), `build` (update image), `run` (launch task)
- 🏃 **`run_ecs.sh`** — container entrypoint that runs pytest, uploads reports to S3, invalidates CloudFront, and notifies Slack (all optional, all controlled by env vars)
- 📊 **`generate_summary.py`** — JUnit XML → summary.json (failed-test names + run-type detection)
- 📋 **`generate_index_html.py`** — static dashboard listing all historical runs, grouped by environment
- 🔄 **GitHub Actions workflow** — daily cron + manual trigger via OIDC (no long-lived AWS keys)

**Monthly AWS cost: under $3 USD** for a team running daily smoke (most cost is Secrets Manager @ $0.40/secret).

---

## Quickstart

```bash
# 1. Deploy AWS infra (creates ECR + S3 + CloudFront + IAM)
aws cloudformation deploy \
  --stack-name pytest-api-kit-infra \
  --template-file templates/cloudformation/infra.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ProjectName=acme-api-tests \
      ReportBucketName=acme-api-reports-$(date +%s)

# 2. Copy template scripts into YOUR pytest repo
cp templates/scripts/*.sh /path/to/your-tests/scripts/
cp templates/scripts/*.py /path/to/your-tests/scripts/
cp templates/docker/Dockerfile /path/to/your-tests/

# 3. Set env vars (see docs/quickstart.md for full list)
export ECS_CLUSTER=acme-cluster
export S3_BUCKET=acme-api-reports-12345
# ... 4 more required vars

# 4. Deploy
cd /path/to/your-tests
./scripts/deploy_ecs.sh setup   # one-time
./scripts/deploy_ecs.sh build   # push image to ECR
./scripts/deploy_ecs.sh run uat # launch first task
```

Open the CloudFront URL (printed by CloudFormation outputs) — your reports
are there.

**Full walkthrough**: [docs/quickstart.md](docs/quickstart.md)

---

## Directory layout

```
pytest-api-kit-aws/
├── templates/
│   ├── docker/
│   │   └── Dockerfile                  ← copy into YOUR pytest repo root
│   ├── scripts/
│   │   ├── deploy_ecs.sh              ← copy into YOUR pytest repo scripts/
│   │   ├── run_ecs.sh                 ← container entrypoint
│   │   ├── generate_summary.py        ← JUnit XML → summary.json
│   │   └── generate_index_html.py     ← S3 reports → dashboard
│   ├── cloudformation/
│   │   └── infra.yaml                 ← one-shot AWS resource creation
│   └── workflows/
│       └── daily-smoke.yml            ← copy into YOUR .github/workflows/
├── docs/
│   ├── quickstart.md                  ← 30-min zero-to-daily-CI
│   └── architecture.md                ← what each AWS resource does + why
└── README.md
```

---

## What's not in here

- **Cognito-gated trigger dashboard** (admin UI, user management, self-service test runs from a web UI) — see [`pytest-api-kit-dashboard`](https://github.com/kao273183/pytest-api-kit-dashboard) (separate repo, adds Cognito + Lambda + a React-free trigger panel)
- **Test code itself** — this repo is pure infrastructure. For the test framework, see [`pytest-api-kit`](https://github.com/kao273183/pytest-api-kit)

---

## Why two repos (`aws` + main kit)?

Because 90% of `pytest-api-kit` users don't run on AWS, and none of them should
have to `pip install boto3` to make their tests pass.

If you're one of the 90%, grab `pytest-api-kit` and use it with GitHub Actions
or your CI of choice. If you have AWS and want a proper report dashboard with
zero ongoing maintenance, come back here.

---

## Licence

MIT — see [LICENSE](LICENSE).

Extracted from a production UAT test rig that's been running daily for 6+ months
without incident. Deployment complexity is real; this template hides the parts
you'd otherwise spend a weekend figuring out.
