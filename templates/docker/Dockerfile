# Dockerfile for running pytest-api-kit tests on AWS Fargate.
#
# Stays minimal on purpose — you adjust:
#   - base image (python:3.11-slim is a sane default)
#   - extra apt deps (tesseract-ocr for captcha OCR, jq for shell JSON, etc.)
#   - TZ (Asia/Taipei here; change for your team)
#
# Build multi-arch for ECS (linux/amd64) from an Apple Silicon mac:
#   docker buildx build --platform linux/amd64 -t ${ECR_URI}:latest --push .

FROM python:3.11-slim

# Tools the ECS entry script needs:
#   - jq:    compose Slack JSON payload
#   - curl:  POST to Slack webhook
#   - tzdata: TZ-aware timestamps
# Add/remove as your tests require (e.g. tesseract-ocr for image captcha OCR).
RUN apt-get update && apt-get install -y --no-install-recommends \
      jq \
      curl \
      ca-certificates \
      tzdata \
    && rm -rf /var/lib/apt/lists/*
ENV TZ=Asia/Taipei

# AWS CLI for S3 upload + CloudFront invalidation
RUN pip install --no-cache-dir awscli

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN chmod +x scripts/run_ecs.sh

# Override with `docker run <image> -k "my_test_name"` to filter
ENTRYPOINT ["scripts/run_ecs.sh"]
