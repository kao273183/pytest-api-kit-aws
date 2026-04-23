# pytest-api-kit-aws

> AWS Fargate deployment templates for `pytest-api-kit`.
> Clone, set env vars, run a script — your API smoke tests run daily on ECS with HTML reports hosted on CloudFront and a Slack notification when anything breaks.

**[繁體中文](#中文版)** | **English**

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

---

## 中文版

### 這是什麼

**`pytest-api-kit-aws`** 是為 [`pytest-api-kit`](https://github.com/kao273183/pytest-api-kit) 量身打造的 AWS Fargate 部署模板。clone 下來改幾個環境變數，跑三行指令就能把你的 API smoke test 搬上雲，每天排程跑、HTML 報告自動上 CloudFront、失敗自動發 Slack。

**月費 AWS 成本不到 $3 美金**（主要成本是 Secrets Manager，每個 secret $0.40/月）。

### 內容

- 🐳 **Dockerfile** — minimal Python 3.11 + awscli + jq
- 📦 **CloudFormation 整套 stack** — 一次建好 ECR + S3 + CloudFront + CloudWatch + IAM 角色
- 🔧 **`deploy_ecs.sh`** — 三段式 workflow：`setup`（一次性）/ `build`（更新 image）/ `run`（啟動 task）
- 🏃 **`run_ecs.sh`** — 容器 entrypoint：跑 pytest → 上傳 S3 → 重建 dashboard → 發 Slack
- 📊 **`generate_summary.py`** — JUnit XML 轉 summary.json
- 📋 **`generate_index_html.py`** — 歷次執行記錄的靜態 dashboard
- 🔄 **GitHub Actions workflow** — 每日 cron + 手動觸發，透過 OIDC 驗證（不用存長期 AWS key）

### 快速開始

```bash
# 1. 一次性部署 AWS 資源（ECR + S3 + CloudFront + IAM）
aws cloudformation deploy \
  --stack-name pytest-api-kit-infra \
  --template-file templates/cloudformation/infra.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ProjectName=acme-api-tests \
      ReportBucketName=acme-api-reports-$(date +%s)

# 2. 把 template 腳本複製到你的 pytest 專案
cp templates/scripts/*.sh /path/to/your-tests/scripts/
cp templates/scripts/*.py /path/to/your-tests/scripts/
cp templates/docker/Dockerfile /path/to/your-tests/

# 3. 設環境變數（完整清單見 docs/quickstart.md）
export ECS_CLUSTER=acme-cluster
export S3_BUCKET=acme-api-reports-12345
# ...還有 4 個必填環境變數

# 4. 部署
cd /path/to/your-tests
./scripts/deploy_ecs.sh setup   # 一次性
./scripts/deploy_ecs.sh build   # 推 image 到 ECR
./scripts/deploy_ecs.sh run uat # 啟動第一次測試
```

打開 CloudFormation 輸出的 CloudFront URL — 報告就在上面。

**完整教學**：[docs/quickstart.md](docs/quickstart.md)

### 適用場景

- **已有 AWS 帳號的公司** — 不用再花週末研究 ECS / IAM / S3 static site 怎麼配
- **QA 想把 daily smoke 從本機排程搬到雲端** — 本地會漏跑、雲端不會
- **非工程同事要看測試結果** — CloudFront 永久 URL，不用 VPN、不用登入

### 不在這裡的東西

- **Cognito 登入儀表板（讓 PM / QA 自助觸發測試）** — 見獨立 repo [`pytest-api-kit-dashboard`](https://github.com/kao273183/pytest-api-kit-dashboard)
- **測試框架本體** — 見 [`pytest-api-kit`](https://github.com/kao273183/pytest-api-kit)

### 授權

MIT — 歡迎 fork 用在任何公司專案。
