#!/bin/bash
# ---------------------------------------------------------------------------
# Container entrypoint:
#   1. Run pytest and capture JUnit + HTML report
#   2. Generate summary.json
#   3. Upload to S3 (if S3_BUCKET is set)
#   4. Rebuild dashboard index.html
#   5. Invalidate CloudFront cache (if CLOUDFRONT_DISTRIBUTION_ID is set)
#   6. Send Slack notification (if SLACK_WEBHOOK_URL is set)
#
# Environment variables consumed:
#   ENVIRONMENT                (default: uat)
#   PYTEST_ARGS                (default: "-m smoke")
#   S3_BUCKET                  (optional)
#   CLOUDFRONT_DISTRIBUTION_ID (optional)
#   CLOUDFRONT_DOMAIN          (optional, e.g. d2xxx.cloudfront.net)
#   SLACK_WEBHOOK_URL          (optional; comma or newline separated for multi)
# ---------------------------------------------------------------------------
set -euo pipefail

TIMESTAMP=$(TZ="${TZ:-UTC}" date +%Y%m%d-%H%M%S)
REPORT_DIR="reports/${TIMESTAMP}"
mkdir -p "${REPORT_DIR}"

echo "=== pytest start [${ENVIRONMENT:-uat}] ${TIMESTAMP} ==="

# Clean any session-level cache that could leak between runs
rm -f data/*_session.json data/*_session_*.json 2>/dev/null || true

# Run pytest; capture exit code so we still upload results on failure
EXIT_CODE=0
PYTEST_ARGS_DEFAULT='-m smoke'
# eval re-parses the quoted args so `-m "smoke and not slow"` works
eval pytest tests/ \
  --junitxml=\"${REPORT_DIR}/report.xml\" \
  --html=\"${REPORT_DIR}/report.html\" \
  --self-contained-html \
  -v --tb=short \
  "${PYTEST_ARGS:-$PYTEST_ARGS_DEFAULT}" "$@" || EXIT_CODE=$?

# ---------------------------------------------------------------------------
# Summary extraction — parse JUnit counts
# ---------------------------------------------------------------------------
TESTS=0; FAILS=0; ERRORS=0; SKIPS=0
if [ -f "${REPORT_DIR}/report.xml" ]; then
  TESTS=$(grep -oP 'tests="\K[^"]+' "${REPORT_DIR}/report.xml" | head -1)
  FAILS=$(grep -oP 'failures="\K[^"]+' "${REPORT_DIR}/report.xml" | head -1)
  ERRORS=$(grep -oP 'errors="\K[^"]+' "${REPORT_DIR}/report.xml" | head -1)
  SKIPS=$(grep -oP 'skipped="\K[^"]+' "${REPORT_DIR}/report.xml" | head -1)
fi

# Optional: richer summary.json if the generator script is available
if [ -f scripts/generate_summary.py ]; then
  python3 scripts/generate_summary.py \
    "${REPORT_DIR}/report.xml" "${REPORT_DIR}/summary.json" \
    "${PYTEST_ARGS:-}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Upload to S3
# ---------------------------------------------------------------------------
if [ -n "${S3_BUCKET:-}" ]; then
  S3_PREFIX="${S3_PREFIX:-pytest-reports}"
  S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${ENVIRONMENT:-uat}/${TIMESTAMP}"
  aws s3 cp "${REPORT_DIR}/" "${S3_PATH}/" --recursive --quiet
  echo "Reports uploaded: ${S3_PATH}/"

  # Rebuild dashboard index if generator is present
  if [ -f scripts/generate_index_html.py ]; then
    S3_BUCKET="${S3_BUCKET}" \
    S3_PREFIX="${S3_PREFIX}/" \
    INDEX_OUTPUT="/tmp/index.html" \
      python3 scripts/generate_index_html.py
    aws s3 cp /tmp/index.html "s3://${S3_BUCKET}/index.html" \
      --content-type "text/html" --quiet
    echo "Dashboard index.html refreshed"
  fi

  # CloudFront cache bust
  if [ -n "${CLOUDFRONT_DISTRIBUTION_ID:-}" ]; then
    aws cloudfront create-invalidation \
      --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
      --paths "/index.html" --output text > /dev/null 2>&1 || true
    echo "CloudFront invalidated"
  fi
fi

# ---------------------------------------------------------------------------
# Console summary (lands in CloudWatch Logs)
# ---------------------------------------------------------------------------
echo "=== pytest done (exit code: ${EXIT_CODE}) ==="
echo "Total: $TESTS  Failures: $FAILS  Errors: $ERRORS  Skipped: $SKIPS"

# ---------------------------------------------------------------------------
# Slack notification
# ---------------------------------------------------------------------------
if [ -n "${SLACK_WEBHOOK_URL:-}" ] && [ -f "${REPORT_DIR}/report.xml" ]; then
  PASS=$((TESTS - FAILS - ERRORS - SKIPS))
  FAIL_TOTAL=$((FAILS + ERRORS))

  if [ -n "${CLOUDFRONT_DOMAIN:-}" ]; then
    REPORT_URL="https://${CLOUDFRONT_DOMAIN}/${S3_PREFIX:-pytest-reports}/${ENVIRONMENT:-uat}/${TIMESTAMP}/report.html?sort=result"
  else
    REPORT_URL="(set CLOUDFRONT_DOMAIN env to get clickable link)"
  fi

  if [ "$EXIT_CODE" = "0" ]; then
    STATUS_ICON=":white_check_mark:"
    COLOR="#2eb886"
  else
    STATUS_ICON=":x:"
    COLOR="#e01e5a"
  fi

  PROJECT_NAME="${PROJECT_NAME:-pytest-api-kit}"
  RUN_TYPE=$(jq -r '.run_type // "full"' "${REPORT_DIR}/summary.json" 2>/dev/null || echo "full")

  FAILED_JSON="[]"
  if [ -f "${REPORT_DIR}/summary.json" ]; then
    FAILED_JSON=$(jq '.failed_tests[:5] // []' "${REPORT_DIR}/summary.json")
  fi

  PAYLOAD=$(jq -nc \
    --arg icon "$STATUS_ICON" \
    --arg proj "$PROJECT_NAME" \
    --arg env "${ENVIRONMENT:-uat}" \
    --arg run_type "$RUN_TYPE" \
    --arg pass "$PASS" \
    --arg fail "$FAIL_TOTAL" \
    --arg skip "$SKIPS" \
    --arg total "$TESTS" \
    --arg ts "$TIMESTAMP" \
    --arg url "$REPORT_URL" \
    --arg color "$COLOR" \
    --argjson failed "$FAILED_JSON" \
    '{
      text: ($icon + " " + $proj + " [" + ($env|ascii_upcase) + "] — " + $run_type),
      attachments: [{
        color: $color,
        blocks: (
          [{
            type: "section",
            fields: [
              {type: "mrkdwn", text: ("*Pass*\n:large_green_circle: " + $pass)},
              {type: "mrkdwn", text: ("*Fail*\n:red_circle: " + $fail)},
              {type: "mrkdwn", text: ("*Skip*\n:white_circle: " + $skip)},
              {type: "mrkdwn", text: ("*Total*\n" + $total)}
            ]
          }]
          + (if ($failed|length) > 0 then
              [{type: "section", text: {type: "mrkdwn",
                text: ("*Failed tests (first 5)*\n" + ($failed|map("• `"+.+"`")|join("\n")))}}]
             else [] end)
          + [{type: "context", elements: [
              {type: "mrkdwn", text: ($ts + "  |  <" + $url + "|:bar_chart: Full report>")}
            ]}]
        )
      }]
    }')

  # SLACK_WEBHOOK_URL can be multiple URLs separated by newlines or commas
  SENT=0; FAILED=0
  while IFS= read -r HOOK; do
    HOOK=$(echo "$HOOK" | tr -d '[:space:],')
    [ -z "$HOOK" ] && continue
    CURL_OUT=$(curl -sS -X POST -H 'Content-type: application/json' \
         --data "$PAYLOAD" "$HOOK" 2>&1) || true
    if [ "$CURL_OUT" = "ok" ]; then
      SENT=$((SENT + 1)); echo "Slack ✓ ${HOOK:0:55}..."
    else
      FAILED=$((FAILED + 1)); echo "Slack ✗ ${HOOK:0:55}...  -> $CURL_OUT"
    fi
  done <<< "$(echo "$SLACK_WEBHOOK_URL" | tr ',' '\n')"
  echo "Slack sent=${SENT} failed=${FAILED}"
fi

exit ${EXIT_CODE}
