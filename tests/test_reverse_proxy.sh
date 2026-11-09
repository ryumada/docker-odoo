#!/usr/bin/env bash
set -o pipefail
# Category: Test
# Description: Reverse proxy rules for Odoo: /queue_job/ (queue_job's unauthenticated runjob route) is closed
#              in every Odoo nginx template and in the Traefik labels setup.sh writes, while the module's static
#              files and the rest of Odoo still pass. Tries the usual ways around a path rule (%-encoding,
#              "//", "/../", another method) and checks the backend never receives a path Odoo would route to
#              queue_job's controllers.
# Usage: ./tests/test_reverse_proxy.sh [nginx|traefik|all]
#        TRAEFIK_BIN=/path/to/traefik (v3) and TRAEFIK_V2_BIN=/path/to/traefik (v2) to test Traefik;
#        NGINX_BIN=/path/to/nginx (default: nginx on PATH or /usr/sbin/nginx).
# Dependencies: bash, python3, curl; nginx and/or traefik (each part is skipped with the reason when missing)
#
# Safe on a real machine: nginx, Traefik and a stand-in backend run as this user on 127.0.0.1 with free ports
# and every file (configs, logs, pid, cache) in one mktemp folder; the system's nginx and its configuration
# are never touched.

readonly C_RESET="\033[0m" C_PASS="\033[0;32m" C_FAIL="\033[0;31m" C_SKIP="\033[1;33m" C_INFO="\033[0;34m"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WHAT="${1:-all}"
passed=0 failed=0 skipped=0
pass() { echo -e "${C_PASS}  [PASS] $1${C_RESET}"; passed=$((passed + 1)); }
fail() { echo -e "${C_FAIL}  [FAIL] $1${C_RESET}"; failed=$((failed + 1)); }
skip() { echo -e "${C_SKIP}  [SKIP] $1: $2${C_RESET}"; skipped=$((skipped + 1)); }
section() { echo -e "${C_INFO}== $1 ==${C_RESET}"; }
case "$WHAT" in nginx|traefik|all) ;; *) echo "Usage: $0 [nginx|traefik|all]" >&2; exit 3 ;; esac
for c in python3 curl; do command -v "$c" >/dev/null 2>&1 || { echo "Missing dependency: $c" >&2; exit 3; }; done

T=$(mktemp -d "${TMPDIR:-/tmp}/test_reverse_proxy.XXXXXX") || exit 3
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  [ -f "$T/nginx.pid" ] && kill "$(cat "$T/nginx.pid")" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }
wait_port() {  # wait_port PORT: until something listens (5 s)
  local i
  for i in $(seq 1 50); do
    python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(s.connect_ex(("127.0.0.1", int(sys.argv[1]))))' "$1" && return 0
    sleep 0.1
  done
  return 1
}

# --- stand-in Odoo: answers every request and logs the request target exactly as it arrived ------------
# (Python's http.server would already turn "//x" into "/x", hiding what the proxy really passed on)
cat > "$T/backend.py" <<'PY'
import socketserver, sys
log = open(sys.argv[2], "a", buffering=1)
class H(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(65537).decode("latin-1").rstrip("\r\n")
        length = 0
        while True:
            h = self.rfile.readline(65537)
            if h in (b"\r\n", b"\n", b""):
                break
            if h.lower().startswith(b"content-length:"):
                length = int(h.split(b":", 1)[1])
        if length:
            self.rfile.read(length)
        parts = line.split(" ")
        if len(parts) < 2:
            return
        log.write(parts[1] + "\n")
        body = ("backend:" + parts[1]).encode()
        self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body))
        if parts[0] != "HEAD":
            self.wfile.write(body)
class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
S(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
BACKEND_PORT=$(free_port); IM_PORT=$(free_port); NODE_PORT=$(free_port)
for p in "$BACKEND_PORT" "$IM_PORT" "$NODE_PORT"; do
  python3 "$T/backend.py" "$p" "$T/backend.log" & PIDS+=($!)
done
for p in "$BACKEND_PORT" "$IM_PORT" "$NODE_PORT"; do wait_port "$p" || { echo "stand-in backend did not start" >&2; exit 3; }; done

# Would Odoo run one of queue_job's controllers for this request target? Odoo's HTTP server is werkzeug's
# request handler: it drops the query, %-decodes the path (so %2F is a "/") and turns a leading "//" into
# "/"; "." and ".." segments are left as they are (no route matches them). A "/" doubled inside the path is
# redirected to the merged path by some werkzeug versions, so it counts as merged here.
odoo_would_run_queue_job() {
  python3 - "$1" <<'PY'
import re, sys, urllib.parse
p = urllib.parse.unquote(sys.argv[1].split("?", 1)[0])
p = re.sub("/+", "/", p)
sys.exit(0 if re.match(r"^/queue_job/(runjob|create_test_job)/?$", p) else 1)
PY
}

DOMAIN=odoo.test.invalid
# request NAME PROXY_PORT METHOD PATH: sets CODE and HIT (yes when the backend got a request)
request() {
  : > "$T/backend.log"
  CODE=$(curl -s -o "$T/body" -w '%{http_code}' --path-as-is -X "$3" -H "Host: $DOMAIN" \
    --max-time 10 "http://127.0.0.1:$2$4" 2>/dev/null)
  sleep 0.05
  HIT=no; [ -s "$T/backend.log" ] && HIT=yes
}
BLOCKED_PATHS=(
  "GET /queue_job/runjob?db=prod&job_uuid=0b4c0e3a-1d2f-4a5b-9c8d-7e6f5a4b3c2d"
  "POST /queue_job/runjob?db=prod&job_uuid=0b4c0e3a-1d2f-4a5b-9c8d-7e6f5a4b3c2d"
  "HEAD /queue_job/runjob"
  "GET /queue_job/create_test_job"
  "GET /queue_job/runjob/"
  "GET /queue%5Fjob/runjob"
  "GET /queue_job%2Frunjob"
  "GET //queue_job/runjob"
  "GET ///queue_job/runjob"
  "GET /queue_job//runjob"
  "GET /web/../queue_job/runjob"
  "GET /queue_job/static/../runjob"
  "GET /queue_job/./runjob"
  "GET /queue_job/static/%2E%2E/runjob"
)
TRICKY_PATHS=(   # the proxy may pass these on, but Odoo must not receive a queue_job route
  "GET /queue_job/static%2F..%2Frunjob"
  "GET /QUEUE_JOB/runjob"
  "GET /queue_job/static/x/..%2F..%2Frunjob"
)
ALLOWED_PATHS=(
  "GET /queue_job/static/description/icon.png"
  "GET /web/login"
  "POST /web/dataset/call_kw/queue.job/search_read"
  "GET /odoo/action-queue_job.action_queue_job"
  "GET /queue_jobs/runjob"
)

check_proxy() {  # check_proxy LABEL PORT
  local label="$1" port="$2" entry method path
  for entry in "${BLOCKED_PATHS[@]}"; do
    method=${entry%% *}; path=${entry#* }
    request x "$port" "$method" "$path"
    if [ "$HIT" = no ] && [ "$CODE" = 404 ]; then pass "$label: $method $path is a 404 that never reaches Odoo"
    elif [ "$HIT" = yes ] && ! odoo_would_run_queue_job "$(tail -n 1 "$T/backend.log")"; then
      pass "$label: $method $path reaches Odoo only as $(tail -n 1 "$T/backend.log") (no queue_job route)"
    else fail "$label: $method $path: HTTP $CODE, Odoo got '$(tail -n 1 "$T/backend.log" 2>/dev/null)'"; fi
  done
  for entry in "${TRICKY_PATHS[@]}"; do
    method=${entry%% *}; path=${entry#* }
    request x "$port" "$method" "$path"
    if [ "$HIT" = yes ] && odoo_would_run_queue_job "$(tail -n 1 "$T/backend.log")"; then
      fail "$label: $method $path reached Odoo as a queue_job route: $(tail -n 1 "$T/backend.log")"
    else pass "$label: $method $path does not reach queue_job (HTTP $CODE${HIT:+, backend $HIT})"; fi
  done
  for entry in "${ALLOWED_PATHS[@]}"; do
    method=${entry%% *}; path=${entry#* }
    request x "$port" "$method" "$path"
    if [ "$CODE" = 200 ] && [ "$HIT" = yes ] && [ "$(tail -n 1 "$T/backend.log")" = "$path" ]; then pass "$label: $method $path still reaches Odoo unchanged"
    else fail "$label: $method $path: HTTP $CODE, Odoo got '$(tail -n 1 "$T/backend.log" 2>/dev/null)'"; fi
  done
}

# ---------------------------------------------------------------------------------------------------------
run_nginx() {
  local NGINX="${NGINX_BIN:-$(command -v nginx 2>/dev/null || { [ -x /usr/sbin/nginx ] && echo /usr/sbin/nginx; })}"
  section "nginx templates"
  if [ -z "$NGINX" ] || [ ! -x "$NGINX" ]; then skip "nginx templates" "nginx not installed (NGINX_BIN to choose one)"; return; fi
  local tpl HTTPS_PORT HTTP80_PORT site
  for tpl in nginx_sites_available nginx_sites_available-with_API nginx_sites_available-localhost nginx_sites_available_path_base_routing_nodejs; do
    HTTPS_PORT=$(free_port); HTTP80_PORT=$(free_port)
    mkdir -p "$T/ng/$tpl/logs" "$T/ng/$tpl/tmp" "$T/ng/$tpl/cache"
    site="$T/ng/$tpl/site.conf"
    # The template as an operator fills it in, with this test's ports and without TLS
    python3 - "$REPO/nginx-configurations/$tpl" "$site" "$DOMAIN" "$BACKEND_PORT" "$IM_PORT" "$NODE_PORT" "$HTTPS_PORT" "$HTTP80_PORT" "$T/ng/$tpl/logs" <<'PY'
import re, sys
src, out, domain, http_port, im_port, node_port, https_port, http80_port, logs = sys.argv[1:10]
s = open(src, encoding="utf-8").read()
s = s.replace("$DOMAIN_static_cache", "test_static_cache").replace("$DOMAIN_image_cache", "test_image_cache")
s = s.replace("$DOMAIN", domain).replace("$HTTP_PORT", http_port).replace("$GEVENT_PORT", im_port)
s = s.replace("$NGINX_HTTP_PORT", https_port)
s = s.replace("127.0.0.1:8069", "127.0.0.1:" + http_port).replace("127.0.0.1:8072", "127.0.0.1:" + im_port)
s = s.replace("127.0.0.1:3000", "127.0.0.1:" + node_port)
s = re.sub(r"listen\s+443\s+ssl;", "listen 127.0.0.1:%s;" % https_port, s)
s = re.sub(r"listen\s+80;", "listen 127.0.0.1:%s;" % http80_port, s)
s = s.replace("listen 0.0.0.0:", "listen 127.0.0.1:")
s = re.sub(r"^\s*(ssl_certificate|ssl_certificate_key|ssl_dhparam|include)\s.*$", "", s, flags=re.M)
s = re.sub(r"(access_log|error_log)\s+/var/log/nginx/([^;\s]+)", lambda m: "%s %s/%s" % (m.group(1), logs, m.group(2)), s)
open(out, "w", encoding="utf-8").write(s)
PY
    cat > "$T/ng/$tpl/nginx.conf" <<NGX
pid $T/nginx.pid;
error_log $T/ng/$tpl/logs/main-error.log;
worker_processes 1;
events { worker_connections 64; }
http {
  access_log $T/ng/$tpl/logs/main-access.log;
  client_body_temp_path $T/ng/$tpl/tmp/body; proxy_temp_path $T/ng/$tpl/tmp/proxy;
  fastcgi_temp_path $T/ng/$tpl/tmp/fcgi; uwsgi_temp_path $T/ng/$tpl/tmp/uwsgi; scgi_temp_path $T/ng/$tpl/tmp/scgi;
  # what setup_nginx_security_conf.sh and setup_nginx_cache_conf.sh install in conf.d
  limit_req_zone \$binary_remote_addr zone=limitweblogin:1m rate=100r/s;
  limit_conn_zone \$binary_remote_addr zone=addrweblogin:1m;
  limit_req_zone \$binary_remote_addr zone=limitwebdatabase:1m rate=100r/s;
  limit_conn_zone \$binary_remote_addr zone=addrwebdatabase:1m;
  proxy_cache_path $T/ng/$tpl/cache/img keys_zone=test_image_cache:1m;
  proxy_cache_path $T/ng/$tpl/cache/static keys_zone=test_static_cache:1m;
  include $site;
}
NGX
    if ! "$NGINX" -p "$T/ng/$tpl" -c "$T/ng/$tpl/nginx.conf" -t > "$T/ng/$tpl/t.log" 2>&1; then
      fail "$tpl: nginx -t rejects the filled-in template: $(grep -v 'alert.*could not open error log' "$T/ng/$tpl/t.log" | tail -n 2 | tr '\n' ' ')"
      continue
    fi
    pass "$tpl: nginx accepts the filled-in template"
    "$NGINX" -p "$T/ng/$tpl" -c "$T/ng/$tpl/nginx.conf" 2>"$T/ng/$tpl/start.log"
    if ! wait_port "$HTTPS_PORT"; then fail "$tpl: nginx did not start: $(tail -n 2 "$T/ng/$tpl/start.log")"; continue; fi
    check_proxy "$tpl" "$HTTPS_PORT"
    [ "$(grep -c 'location ~ ^/queue_job/(?!static/)' "$REPO/nginx-configurations/$tpl")" = 1 ] \
      && pass "$tpl: one queue_job rule" || fail "$tpl: expected exactly one queue_job rule"
    kill "$(cat "$T/nginx.pid")" 2>/dev/null
    for _ in $(seq 1 50); do [ -f "$T/nginx.pid" ] || break; sleep 0.1; done
    rm -f "$T/nginx.pid"
  done
}

# ---------------------------------------------------------------------------------------------------------
traefik_labels_from_setup() {
  # Runs the label-building lines of setup.sh (the real code) and writes them into a copy of
  # docker-compose.yml.example exactly as setup.sh does.
  local snippet compose="$T/docker-compose.yml"
  snippet=$(python3 - "$REPO/setup.sh" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
start = next(i for i, l in enumerate(lines) if l.strip().startswith('local traefik_labels="    labels:'))
end = next(i for i in range(start, len(lines)) if "<<TRAEFIK_LABELS_PLACEHOLDER>>" in lines[i] and "sed -i" in lines[i])
print("\n".join(l.replace("local traefik_labels=", "traefik_labels=") for l in lines[start:end + 1]))
PY
) || return 1
  cp "$REPO/docker-compose.yml.example" "$compose"
  ( SERVICE_NAME=svc TRAEFIK_DOMAIN="$DOMAIN" TRAEFIK_NETWORK=proxy TRAEFIK_CERTRESOLVER=le \
    TARGET_PORT="$BACKEND_PORT" TARGET_GEVENT_PORT="$IM_PORT" DOCKER_COMPOSE_FILE="$compose" ws_path=/websocket
    eval "$snippet" ) || return 1
  echo "$compose"
}

run_traefik() {
  section "Traefik labels (setup.sh, REVERSE_PROXY_TYPE=traefik)"
  local compose
  compose=$(traefik_labels_from_setup) || { fail "could not build the Traefik labels from setup.sh"; return; }
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 - "$compose" > "$T/labels.txt" <<'PY' && pass "docker-compose.yml with the labels is valid YAML" || fail "docker-compose.yml with the labels is not valid YAML: $(tail -n 1 "$T/labels.txt")"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for l in d["services"]["odoo"]["labels"]:
    print(l)
PY
  else
    sed -n "s/^      - '\(traefik\..*\)'$/\1/p" "$compose" > "$T/labels.txt"
    skip "docker-compose.yml YAML check" "python3 yaml module not installed (labels read with sed)"
  fi
  grep -qF 'traefik.http.routers.odoo-qj-svc.rule=Host("odoo.test.invalid") && ((PathPrefix("/queue_job/") && !PathPrefix("/queue_job/static/")) || PathPrefix("//"))' "$T/labels.txt" \
    && pass "the queue_job router rule is written as intended" || fail "queue_job router rule: $(grep 'odoo-qj-svc.rule' "$T/labels.txt")"

  local bin ver
  for ver in v3 v2; do
    if [ "$ver" = v3 ]; then bin="${TRAEFIK_BIN:-}"; else bin="${TRAEFIK_V2_BIN:-}"; fi
    if [ -z "$bin" ] || [ ! -x "$bin" ]; then
      skip "Traefik $ver" "set $([ "$ver" = v3 ] && echo TRAEFIK_BIN || echo TRAEFIK_V2_BIN) to a traefik $ver binary"
      continue
    fi
    local port dyn
    port=$(free_port); dyn="$T/traefik-$ver.yml"
    # The labels as the file provider's dynamic configuration (same keys; TLS left out, the service port
    # becomes a URL on 127.0.0.1, as the Docker provider would resolve it)
    python3 - "$T/labels.txt" "$dyn" <<'PY' || { fail "Traefik $ver: could not convert the labels"; continue; }
import json, sys
cfg = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line.startswith("traefik.http."):
        continue
    key, value = line.split("=", 1)
    parts = key.split(".")[2:]
    if parts[-1] in ("tls", "certresolver") or parts[-2:] == ["tls", "certresolver"] or "tls" in parts:
        continue
    if parts[0] == "services" and parts[-3:] == ["loadbalancer", "server", "port"]:
        cfg.setdefault("services", {}).setdefault(parts[1], {})["loadBalancer"] = {"servers": [{"url": "http://127.0.0.1:%s" % value}]}
        continue
    node = cfg
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    if parts[-1] == "entrypoints" or parts[-1] == "middlewares":
        value = value.split(",")
    elif parts[-1] == "priority":
        value = int(value)
    node[parts[-1]] = value
json.dump({"http": cfg}, open(sys.argv[2], "w"), indent=2)   # JSON is valid YAML
PY
    "$bin" --entrypoints.websecure.address="127.0.0.1:$port" --providers.file.filename="$dyn" \
      --log.level=ERROR --log.filepath="$T/traefik-$ver.log" > "$T/traefik-$ver.out" 2>&1 &
    PIDS+=($!)
    local ready=no
    for _ in $(seq 1 100); do
      request x "$port" GET /web/login
      [ "$CODE" = 200 ] && { ready=yes; break; }
      sleep 0.1
    done
    if [ "$ready" != yes ]; then fail "Traefik $ver did not route to Odoo: $(tail -n 3 "$T/traefik-$ver.log" "$T/traefik-$ver.out" 2>/dev/null | tr '\n' ' ')"; continue; fi
    pass "Traefik $ver: routes the deployment from the labels"
    check_proxy "Traefik $ver" "$port"
    if grep -qi 'error' "$T/traefik-$ver.log" 2>/dev/null; then
      fail "Traefik $ver logged errors: $(grep -i error "$T/traefik-$ver.log" | tail -n 2 | tr '\n' ' ')"
    else pass "Traefik $ver: no configuration errors"; fi
  done
}

[ "$WHAT" = nginx ] || [ "$WHAT" = all ] && run_nginx
[ "$WHAT" = traefik ] || [ "$WHAT" = all ] && run_traefik

echo
echo -e "Results: ${C_PASS}$passed passed${C_RESET}, ${C_FAIL}$failed failed${C_RESET}, ${C_SKIP}$skipped skipped${C_RESET}"
[ "$failed" -eq 0 ]
