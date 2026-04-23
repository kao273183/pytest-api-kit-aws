# Architecture

```
                           ┌──────────────────────┐
                           │  GitHub Actions      │
                           │  cron + manual run   │
                           └──────────┬───────────┘
                                      │ assume OIDC role
                                      │ ecs run-task
                                      ▼
┌─────────────────────────────────────────────────────────────┐
│                        AWS account                          │
│                                                             │
│   ┌────────────┐                ┌──────────────────────┐   │
│   │    ECR     │◄──── push ─────│   Docker Build       │   │
│   │   (image)  │                │   (local / CI)       │   │
│   └─────┬──────┘                └──────────────────────┘   │
│         │ pull                                              │
│         ▼                                                   │
│   ┌────────────┐         run_ecs.sh                         │
│   │  Fargate   │──── pytest ───► Cache/tokens               │
│   │   task     │                                            │
│   │            │──── S3 PUT ──► ┌──────────────┐            │
│   └────────────┘                │  S3 bucket   │◄──┐        │
│         │                       │ reports/     │   │        │
│         │ stdout                │   index.html │   │ CDN    │
│         ▼                       └──────────────┘   │        │
│   ┌────────────┐                       │            │        │
│   │ CloudWatch │                       └──► CloudFront ──►  │
│   │    Logs    │                                  (public   │
│   └────────────┘                                   HTTPS)   │
│                                                             │
│   ┌────────────┐                                            │
│   │  Secrets   │◄──── task role reads ──── Fargate task     │
│   │  Manager   │                                            │
│   └────────────┘                                            │
└─────────────────────────────────────────────────────────────┘
                                      │
                                      │ https webhook
                                      ▼
                              ┌──────────────┐
                              │    Slack     │
                              └──────────────┘
```

## What each AWS resource is for

| Resource | Purpose | Cost implications |
|---|---|---|
| **ECR** | Store the test-runner Docker image | ~$0.10/GB/month, first 500MB free |
| **S3 bucket** | Store pytest HTML reports + JSON summaries + static dashboard | Pennies — reports are tiny JSON/HTML |
| **CloudFront** | HTTPS in front of S3 (S3 website endpoint is HTTP only) + global cache | Free tier 1TB transfer/month |
| **ECS Fargate** | Run the test container on demand | Pay per second of task runtime. 0.5vCPU / 1GB memory ≈ $0.015/task run |
| **CloudWatch Logs** | Task stdout (pytest output + Slack messages) | ~$0.50/GB ingestion; 30-day retention in template |
| **Secrets Manager** | Hold credentials (API passwords, Slack webhooks) | $0.40/secret/month |
| **IAM roles** | Two roles: task-execution (pull image, read secrets) + task (write S3, invalidate CloudFront) | Free |

**Typical monthly cost for a team running daily smoke**: under **$3 USD**.

## Why Fargate, not Lambda?

- Lambda max 15min runtime; a 170-test UAT suite can exceed that
- Fargate gives you a proper filesystem + long-running network (WebSocket, streaming APIs)
- Easier to debug (one SSH via ECS Exec beats a zillion CloudWatch log events)

If your test suite is tiny (<10min) and pure request/response, Lambda is
cheaper — but that's not what this template is for.

## Why S3 + CloudFront, not a fancy dashboard app?

- Static HTML scales to infinity for zero infra cost
- `pytest-html` reports are already self-contained HTML — no server needed
- Non-engineers can deep-link to a specific run
- No login flow to maintain (if you need one, see `pytest-api-kit-dashboard`
  which adds Cognito SSO on top)

## Task lifecycle

```
 GH Actions            Fargate task                  S3 bucket                CloudFront
─────────              ─────────────                 ────────────             ──────────
     │ run-task            │                              │                        │
     ├───────────────────►│                              │                        │
     │                    │ 1. pip install               │                        │
     │                    │ 2. pytest tests/             │                        │
     │                    │ 3. generate_summary.py       │                        │
     │                    │ 4. aws s3 cp reports/ ──────►│                        │
     │                    │ 5. generate_index_html.py    │                        │
     │                    │ 6. aws s3 cp index.html ────►│                        │
     │                    │ 7. cloudfront invalidate ─────────────────────────────►│
     │                    │ 8. curl Slack webhook                                 │
     │ task stopped       │                              │                        │
     │◄───────────────────┤ exit EXIT_CODE                                        │
```

## Customisation points

| Where | Why you'd change it |
|---|---|
| `Dockerfile` | Add apt packages (e.g. `tesseract-ocr` for captcha OCR, `libxml2` for `lxml`) |
| `deploy_ecs.sh` → `_register_task_definition` | Add more env vars / secrets specific to your auth flow |
| `run_ecs.sh` → Slack payload | Customise the message format / add @here on failure |
| `generate_index_html.py` | Add environment filters, link to JUnit XML, latency charts |
| `cloudformation/infra.yaml` → CloudFront | Add custom domain + ACM cert + WAF if internal-only |
