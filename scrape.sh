#!/bin/bash
set -eu

# --- Parse command line arguments ---
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -e, --endpoint URL        RGW endpoint URL (env: RGW_ENDPOINT)
  -a, --access-key KEY      S3 access key with admin caps (env: ACCESS_KEY)
  -s, --secret-key KEY      S3 secret key, use '-' to read from stdin (env: SECRET_KEY)
  -S, --store NAME          Store name added to metrics (env: STORE, default: default)
  -i, --interval SECONDS    Scrape interval (env: SCRAPE_INTERVAL, default: 60)
  -d, --metrics-dir PATH    Directory to write metrics (env: METRICS_DIR, default: /metrics)
  -p, --admin-path PATH     Admin API path (env: ADMIN_PATH, default: admin)
  -t, --timeout SECONDS     Request timeout (env: TIMEOUT, default: 60)
  -h, --help                Show this help message

CLI arguments take precedence over environment variables.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -e|--endpoint)    RGW_ENDPOINT="$2"; shift 2 ;;
    -a|--access-key)  ACCESS_KEY="$2"; shift 2 ;;
    -s|--secret-key)  SECRET_KEY="$2"; shift 2 ;;
    -S|--store)       STORE="$2"; shift 2 ;;
    -i|--interval)    SCRAPE_INTERVAL="$2"; shift 2 ;;
    -d|--metrics-dir) METRICS_DIR="$2"; shift 2 ;;
    -p|--admin-path)  ADMIN_PATH="$2"; shift 2 ;;
    -t|--timeout)     TIMEOUT="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Configuration: CLI args (set above) take precedence, then env vars, then defaults ---
RGW_ENDPOINT="${RGW_ENDPOINT:?Required: RGW endpoint URL (e.g. http://rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80)}"
ACCESS_KEY="${ACCESS_KEY:?Required: S3 access key with admin caps}"
SECRET_KEY="${SECRET_KEY:?Required: S3 secret key}"

# If secret key is '-', read from stdin
if [ "$SECRET_KEY" = "-" ]; then
  IFS= read -r SECRET_KEY
  [ -n "$SECRET_KEY" ] || { echo "Error: empty secret key from stdin" >&2; exit 1; }
fi

STORE="${STORE:-default}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-60}"
METRICS_DIR="${METRICS_DIR:-/metrics}"
ADMIN_PATH="${ADMIN_PATH:-admin}"
TIMEOUT="${TIMEOUT:-60}"

# --- Helpers ---

# Make authenticated request to RGW Admin Ops API
rgw_request() {
  curl -sf \
    --aws-sigv4 "aws:amz:us-east-1:s3" \
    -H "Host: " \
    -u "${ACCESS_KEY}:${SECRET_KEY}" \
    --connect-timeout 10 \
    --max-time "${TIMEOUT}" \
    -k \
    "${RGW_ENDPOINT}/${ADMIN_PATH}/${1}?format=json&${2:-}" || true
}

# jq helpers reused across metric families (defined as shell variables, concatenated into jq programs)
JQ_ESC='def esc: gsub("\\\\"; "\\\\") | gsub("\""; "\\\"");'

# --- Usage metrics (ops and bytes per bucket/owner/category) ---

collect_usage() {
  local file="$1"
  local agg="${tmp}/usage_agg.json"

  # Aggregate across usage log bins (RGW splits into 1000-entry chunks)
  if [ -s "$file" ]; then
    jq -c '
      [.entries[]? | (.owner // .user) as $o |
        .buckets[]? |
        (if .bucket == "" or .bucket == null then "bucket_root" else .bucket end) as $b |
        .categories[]? |
        {o: $o, b: $b, c: .category, ops: .ops, so: .successful_ops, bs: .bytes_sent, br: .bytes_received}
      ] | group_by([.o, .b, .c]) | map({
        bucket: .[0].b, owner: .[0].o, category: .[0].c,
        ops: ([.[].ops] | add), so: ([.[].so] | add),
        bs: ([.[].bs] | add), br: ([.[].br] | add)
      })' < "$file" > "$agg" 2>/dev/null || echo '[]' > "$agg"
  else
    echo '[]' > "$agg"
  fi

  local jq_l="${JQ_ESC}"'
    def l($s): "{bucket=\"\(.bucket|esc)\",owner=\"\(.owner|esc)\",category=\"\(.category|esc)\",store=\"\($s)\"}";'

  echo '# HELP radosgw_usage_ops_total Number of operations'
  echo '# TYPE radosgw_usage_ops_total counter'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_ops_total\(l($s)) \(.ops)"
  ' "$agg" 2>/dev/null || true

  echo '# HELP radosgw_usage_successful_ops_total Number of successful operations'
  echo '# TYPE radosgw_usage_successful_ops_total counter'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_successful_ops_total\(l($s)) \(.so)"
  ' "$agg" 2>/dev/null || true

  echo '# HELP radosgw_usage_sent_bytes_total Bytes sent by the RADOSGW'
  echo '# TYPE radosgw_usage_sent_bytes_total counter'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_sent_bytes_total\(l($s)) \(.bs)"
  ' "$agg" 2>/dev/null || true

  echo '# HELP radosgw_usage_received_bytes_total Bytes received by the RADOSGW'
  echo '# TYPE radosgw_usage_received_bytes_total counter'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_received_bytes_total\(l($s)) \(.br)"
  ' "$agg" 2>/dev/null || true
}

# --- Bucket metrics (size, objects, quotas, shards) ---

collect_buckets() {
  local file="$1"
  local parsed="${tmp}/buckets_parsed.json"

  if [ -s "$file" ]; then
    jq -c '[.[]? | select(type == "object") | {
      b: .bucket, o: .owner, z: (.zonegroup // "0"),
      bytes: (.usage["rgw.main"].size_actual // 0),
      util: (.usage["rgw.main"].size_utilized // 0),
      obj: (.usage["rgw.main"].num_objects // 0),
      shards: (.num_shards // 0),
      qe: (if .bucket_quota.enabled then 1 else 0 end),
      qs: (.bucket_quota.max_size // 0),
      qsb: ((.bucket_quota.max_size_kb // 0) * 1024),
      qo: (.bucket_quota.max_objects // 0)
    }]' < "$file" > "$parsed" 2>/dev/null || echo '[]' > "$parsed"
  else
    echo '[]' > "$parsed"
  fi

  local jq_l="${JQ_ESC}"'
    def l($s): "{bucket=\"\(.b|esc)\",owner=\"\(.o|esc)\",zonegroup=\"\(.z|esc)\",store=\"\($s)\"}";'

  echo '# HELP radosgw_usage_bucket_bytes Bucket used bytes'
  echo '# TYPE radosgw_usage_bucket_bytes gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_bytes\(l($s)) \(.bytes)"
  ' "$parsed" 2>/dev/null || true

  echo '# HELP radosgw_usage_bucket_utilized_bytes Bucket utilized bytes'
  echo '# TYPE radosgw_usage_bucket_utilized_bytes gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_utilized_bytes\(l($s)) \(.util)"
  ' "$parsed" 2>/dev/null || true

  echo '# HELP radosgw_usage_bucket_objects Number of objects in bucket'
  echo '# TYPE radosgw_usage_bucket_objects gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_objects\(l($s)) \(.obj)"
  ' "$parsed" 2>/dev/null || true

  echo '# HELP radosgw_usage_bucket_quota_enabled Quota enabled for bucket'
  echo '# TYPE radosgw_usage_bucket_quota_enabled gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_quota_enabled\(l($s)) \(.qe)"
  ' "$parsed" 2>/dev/null || true

  echo '# HELP radosgw_usage_bucket_quota_size Maximum allowed bucket size'
  echo '# TYPE radosgw_usage_bucket_quota_size gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_quota_size\(l($s)) \(.qs)"
  ' "$parsed" 2>/dev/null || true

  echo '# HELP radosgw_usage_bucket_quota_size_bytes Maximum allowed bucket size in bytes'
  echo '# TYPE radosgw_usage_bucket_quota_size_bytes gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_quota_size_bytes\(l($s)) \(.qsb)"
  ' "$parsed" 2>/dev/null || true

  echo '# HELP radosgw_usage_bucket_quota_size_objects Maximum allowed bucket size in number of objects'
  echo '# TYPE radosgw_usage_bucket_quota_size_objects gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_quota_size_objects\(l($s)) \(.qo)"
  ' "$parsed" 2>/dev/null || true

  echo '# HELP radosgw_usage_bucket_shards Number of shards in bucket'
  echo '# TYPE radosgw_usage_bucket_shards gauge'
  jq -r --arg s "$STORE" "${jq_l}"'
    .[] | "radosgw_usage_bucket_shards\(l($s)) \(.shards)"
  ' "$parsed" 2>/dev/null || true
}

# --- User metrics (metadata, quotas, totals) ---

collect_users() {
  local file="$1"
  local all_users="${tmp}/all_users.jsonl"

  # Get user list from API response
  local users=""
  if [ -s "$file" ]; then
    users=$(jq -r '.keys[]?' < "$file" 2>/dev/null) || true
    # Fallback for older Ceph versions (pre 12.2.13 / 13.2.9)
    if [ -z "$users" ]; then
      users=$(jq -r '.[]?' < "$file" 2>/dev/null) || true
    fi
  fi

  # Fetch info for each user (writes JSONL: one JSON object per line)
  : > "$all_users"
  if [ -n "$users" ]; then
    echo "$users" | while IFS= read -r user; do
      [ -n "$user" ] || continue
      user_info=$(rgw_request "user" "uid=${user}&stats=True")
      [ -n "$user_info" ] && echo "$user_info" >> "$all_users"
    done
  fi

  # user_metadata has a unique label set
  echo '# HELP radosgw_user_metadata User metadata'
  echo '# TYPE radosgw_user_metadata gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${JQ_ESC}"'
    .[] | "radosgw_user_metadata{user=\"\(.user_id|esc)\",display_name=\"\((.display_name // "")|esc)\",email=\"\((.email // "")|esc)\",storage_class=\"\((.default_storage_class // "")|esc)\",store=\"\($s)\"} 1"
  ' "$all_users" 2>/dev/null || true

  # user total stats
  echo '# HELP radosgw_usage_user_total_bytes Usage of bytes by user'
  echo '# TYPE radosgw_usage_user_total_bytes gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${JQ_ESC}"'
    .[] | select(.stats) | "radosgw_usage_user_total_bytes{user=\"\(.user_id|esc)\",store=\"\($s)\"} \(.stats.size_actual // 0)"
  ' "$all_users" 2>/dev/null || true

  echo '# HELP radosgw_usage_user_total_objects Usage of objects by user'
  echo '# TYPE radosgw_usage_user_total_objects gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${JQ_ESC}"'
    .[] | select(.stats) | "radosgw_usage_user_total_objects{user=\"\(.user_id|esc)\",store=\"\($s)\"} \(.stats.num_objects // 0)"
  ' "$all_users" 2>/dev/null || true

  # jq label helper for user metrics (user + store labels only)
  local jq_l="${JQ_ESC}"'
    def l($s): "{user=\"\(.user_id|esc)\",store=\"\($s)\"}";'

  # user quota metrics
  echo '# HELP radosgw_usage_user_quota_enabled User quota enabled'
  echo '# TYPE radosgw_usage_user_quota_enabled gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.user_quota) | "radosgw_usage_user_quota_enabled\(l($s)) \(if .user_quota.enabled then 1 else 0 end)"
  ' "$all_users" 2>/dev/null || true

  echo '# HELP radosgw_usage_user_quota_size Maximum allowed size for user'
  echo '# TYPE radosgw_usage_user_quota_size gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.user_quota) | "radosgw_usage_user_quota_size\(l($s)) \(.user_quota.max_size // 0)"
  ' "$all_users" 2>/dev/null || true

  echo '# HELP radosgw_usage_user_quota_size_bytes Maximum allowed size in bytes for user'
  echo '# TYPE radosgw_usage_user_quota_size_bytes gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.user_quota) | "radosgw_usage_user_quota_size_bytes\(l($s)) \((.user_quota.max_size_kb // 0) * 1024)"
  ' "$all_users" 2>/dev/null || true

  echo '# HELP radosgw_usage_user_quota_size_objects Maximum allowed number of objects across all user buckets'
  echo '# TYPE radosgw_usage_user_quota_size_objects gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.user_quota) | "radosgw_usage_user_quota_size_objects\(l($s)) \(.user_quota.max_objects // 0)"
  ' "$all_users" 2>/dev/null || true

  # per-bucket quota metrics (per user)
  echo '# HELP radosgw_usage_user_bucket_quota_enabled User per-bucket-quota enabled'
  echo '# TYPE radosgw_usage_user_bucket_quota_enabled gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.bucket_quota) | "radosgw_usage_user_bucket_quota_enabled\(l($s)) \(if .bucket_quota.enabled then 1 else 0 end)"
  ' "$all_users" 2>/dev/null || true

  echo '# HELP radosgw_usage_user_bucket_quota_size Maximum allowed size for each bucket of user'
  echo '# TYPE radosgw_usage_user_bucket_quota_size gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.bucket_quota) | "radosgw_usage_user_bucket_quota_size\(l($s)) \(.bucket_quota.max_size // 0)"
  ' "$all_users" 2>/dev/null || true

  echo '# HELP radosgw_usage_user_bucket_quota_size_bytes Maximum allowed size in bytes for each bucket of user'
  echo '# TYPE radosgw_usage_user_bucket_quota_size_bytes gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.bucket_quota) | "radosgw_usage_user_bucket_quota_size_bytes\(l($s)) \((.bucket_quota.max_size_kb // 0) * 1024)"
  ' "$all_users" 2>/dev/null || true

  echo '# HELP radosgw_usage_user_bucket_quota_size_objects Maximum allowed number of objects in each user bucket'
  echo '# TYPE radosgw_usage_user_bucket_quota_size_objects gauge'
  [ -s "$all_users" ] && jq -rs --arg s "$STORE" "${jq_l}"'
    .[] | select(.bucket_quota) | "radosgw_usage_user_bucket_quota_size_objects\(l($s)) \(.bucket_quota.max_objects // 0)"
  ' "$all_users" 2>/dev/null || true
}

# --- Main loop ---
mkdir -p "${METRICS_DIR}"
printf 'Starting RGW usage scraper\n  Endpoint: %s\n  Store: %s\n  Interval: %ss\n' \
  "$RGW_ENDPOINT" "$STORE" "$SCRAPE_INTERVAL"

while true; do
  start_time=$(date +%s)
  tmp="${METRICS_DIR}/.tmp"
  mkdir -p "$tmp"
  # Fetch data from RGW Admin Ops API
  rgw_request "usage" "show-summary=False" > "${tmp}/usage.json"
  rgw_request "bucket" "stats=True" > "${tmp}/buckets.json"
  rgw_request "user" "list" > "${tmp}/users.json"

  # Only update metrics if at least one API call returned data
  if [ -s "${tmp}/usage.json" ] || [ -s "${tmp}/buckets.json" ] || [ -s "${tmp}/users.json" ]; then
    {
      collect_usage "${tmp}/usage.json"
      collect_buckets "${tmp}/buckets.json"
      collect_users "${tmp}/users.json"

      end_time=$(date +%s)
      echo '# HELP radosgw_usage_scrape_duration_seconds Time to scrape RGW metrics'
      echo '# TYPE radosgw_usage_scrape_duration_seconds gauge'
      echo "radosgw_usage_scrape_duration_seconds $((end_time - start_time))"

      echo '# HELP radosgw_usage_scrape_success Whether the last scrape succeeded'
      echo '# TYPE radosgw_usage_scrape_success gauge'
      echo 'radosgw_usage_scrape_success 1'
    } > "${METRICS_DIR}/.metrics.tmp"

    mv "${METRICS_DIR}/.metrics.tmp" "${METRICS_DIR}/metrics.prom"
  else
    printf 'WARNING: All API calls returned empty, keeping previous metrics\n' >&2
  fi

  rm -rf "$tmp"
  sleep "${SCRAPE_INTERVAL}"
done
