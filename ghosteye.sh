#!/usr/bin/env bash
#
# ghosteye.sh — Recon → Exploit pipeline
#
#   ./ghosteye.sh target.com
#   ./ghosteye.sh target.com --deep
#
# AUTHORIZED TARGETS ONLY. You are responsible for scope compliance.

set -uo pipefail

# ───────────────────────────── config ─────────────────────────────

TARGET=""
OUT=""
DEEP=0

WL_DIR="/usr/share/seclists/Discovery/Web-Content"
WL_CONTENT="$WL_DIR/common.txt"
# raft-medium is 30k directory names. DirBuster-2.3-medium is 220k — with
# -recursion that is hours per host, so it is deliberately not used here.
WL_DEEP="$WL_DIR/raft-medium-directories.txt"

# naabu 2.6.1 silently returns nothing for -top-ports on this VM; an explicit
# list with a connect scan is reliable. Curated: common + app/db/remote ports.
PORTS="21,22,23,25,53,80,110,111,135,139,143,443,445,993,995,1723,2049,3306,3389,5432,5900,6379,8000,8008,8080,8081,8443,8888,9000,9090,9200,9443,10000,27017"

THREADS="${GHOSTEYE_THREADS:-50}"
RATE="${GHOSTEYE_RATE:-150}"
HTTPX_TIMEOUT="${GHOSTEYE_TIMEOUT:-10}"

# gowitness needs a Chrome/Chromium binary. Its default chromedp driver times
# out on this VM; the gorod driver works. It writes .jpeg, not .png.
CHROME="${GHOSTEYE_CHROME:-$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)}"

# ─────────────────────────────── ui ───────────────────────────────

# Colour only when we own the terminal. Keeps piped/redirected output clean
# (ANSI escapes in a logfile break grep, jq and friends downstream).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
  C_DIM=$'\033[2m';   C_MAG=$'\033[1;35m';  C_BOLD=$'\033[1m'
  C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_MAG=""; C_BOLD=""; C_OFF=""
fi

STAGE_NO=0
STAGE_TOTAL=10  # +1 in --deep (port scan)
START_TS=$(date +%s)

log()  { printf '  %s▸%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '  %s✘%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }

stage() {
  STAGE_NO=$((STAGE_NO + 1))
  printf '\n%s┌─[%d/%d]%s %s%s%s\n' \
    "$C_DIM" "$STAGE_NO" "$STAGE_TOTAL" "$C_OFF" "$C_BOLD" "$1" "$C_OFF"
}

rule() { printf '%s%s%s\n' "$C_DIM" "$(printf '─%.0s' {1..64})" "$C_OFF"; }

banner() {
  printf '\n%s' "$C_MAG"
  cat <<'ART'
   ▄████  ██░ ██  ▒█████    ██████ ▄▄▄█████▓▓█████▓██   ██▓
  ██▒ ▀█▒▓██░ ██▒▒██▒  ██▒▒██    ▒ ▓  ██▒ ▓▒▓█   ▀ ▒██  ██▒
 ▒██░▄▄▄░▒██▀▀██░▒██░  ██▒░ ▓██▄   ▒ ▓██░ ▒░▒███    ▒██ ██░
 ░▓█  ██▓░▓█ ░██ ▒██   ██░  ▒   ██▒░ ▓██▓ ░ ▒▓█  ▄  ░▓█ ░██
 ░▒▓███▀▒░▓█▒░██▓░ ████▓▒░▒██████▒▒  ▒██▒ ░ ░▒████▒ ░▓█▒░██▓
  ░▒   ▒  ▒ ░░▒░▒░ ▒░▒░▒░ ▒ ▒▓▒ ▒ ░  ▒ ░░   ░░ ▒░ ░  ▒ ░░▒░▒
ART
  printf '%s' "$C_OFF"
  printf '  %srecon → exploit pipeline%s\n' "$C_DIM" "$C_OFF"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Run a command, swallow its noise, keep the pipeline alive on failure.
run() {
  local label="$1"; shift
  log "$label"
  "$@" >/dev/null 2>&1 || warn "$label failed (continuing)"
}

usage() {
  cat <<EOF
${C_BOLD}ghosteye${C_OFF} — recon → exploit pipeline

  ./ghosteye.sh <target> [--deep]

  --deep    bigger wordlist, recursive fuzzing, port scan (naabu)
EOF
  exit 0
}

# ──────────────────────────── arguments ───────────────────────────

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage ;;
    --deep)    DEEP=1 ;;
    -*)        err "unknown flag: $arg"; exit 2 ;;
    *)         [ -z "$TARGET" ] && TARGET="$arg" || { err "one target at a time"; exit 2; } ;;
  esac
done

[ -z "$TARGET" ] && usage

# strip scheme/trailing slash so subfinder and friends get a bare domain
TARGET="${TARGET#http://}"; TARGET="${TARGET#https://}"; TARGET="${TARGET%%/*}"

[ "$DEEP" = 1 ] && { WL_CONTENT="$WL_DEEP"; STAGE_TOTAL=11; }

OUT="ghostyjoe_$TARGET"

banner
printf '  %starget%s  %s\n' "$C_DIM" "$C_OFF" "$TARGET"
printf '  %smode%s    %s\n' "$C_DIM" "$C_OFF" "$([ "$DEEP" = 1 ] && echo deep || echo standard)"
printf '  %soutput%s  %s/\n' "$C_DIM" "$C_OFF" "$OUT"

# ──────────────────────────── preflight ───────────────────────────

stage "preflight"
missing=0
for t in subfinder httpx gau katana ffuf nuclei; do
  if have "$t"; then ok "$t"; else err "$t not found"; missing=1; fi
done
have assetfinder || warn "assetfinder missing — subdomain pass will be thinner"
have hakrawler   || warn "hakrawler missing — crawling pass will be thinner"
have gowitness   || warn "gowitness missing — no screenshots"
{ have gowitness && [ -z "$CHROME" ]; } && warn "no chromium binary — screenshots will be skipped"
[ -f "$WL_CONTENT" ] || { err "wordlist missing: $WL_CONTENT"; missing=1; }
[ "$missing" = 1 ] && { err "required tooling absent — aborting"; exit 1; }

mkdir -p "$OUT"
cd "$OUT" || exit 1
: > subs.txt; : > live.txt; : > urls.txt

# ───────────────────────── 1. subdomains ──────────────────────────

stage "subdomain discovery"
have subfinder   && run "subfinder"   subfinder -d "$TARGET" -silent -o subs.txt
have assetfinder && run "assetfinder" bash -c "assetfinder --subs-only '$TARGET' >> subs.txt"
printf '%s\n' "$TARGET" >> subs.txt
sort -u subs.txt -o subs.txt
ok "$(wc -l < subs.txt | tr -d ' ') unique hosts"

# ───────────────────────── 2. live hosts ──────────────────────────

stage "live host probing"
if have httpx; then
  run "httpx" httpx -l subs.txt -silent -o live.txt -threads "$THREADS" -timeout "$HTTPX_TIMEOUT"
  # second pass keeps status/title/tech for the report, not for piping
  httpx -l subs.txt -silent -sc -title -td -timeout "$HTTPX_TIMEOUT" \
        -o live_full.txt >/dev/null 2>&1 || true
fi
[ -s live.txt ] || printf 'https://%s\n' "$TARGET" > live.txt
ok "$(wc -l < live.txt | tr -d ' ') live hosts"

# ─────────────────────── 3. endpoint discovery ────────────────────

stage "endpoint discovery"
# gau reads a DOMAIN argument — it does not consume stdin.
if have gau; then
  log "gau"
  gau --subs --threads 5 --timeout 30 "$TARGET" 2>/dev/null \
    | sort -u >> urls.txt || warn "gau failed (continuing)"
fi
# katana and hakrawler both take the live-host list.
have katana   && run "katana"   bash -c "katana -list live.txt -silent -jc -d 3 >> urls.txt"
have hakrawler && run "hakrawler" bash -c "hakrawler -d 2 -subs < live.txt >> urls.txt"
sort -u urls.txt -o urls.txt
ok "$(wc -l < urls.txt | tr -d ' ') endpoints"

# ──────────────────── 3b. port scan (--deep only) ─────────────────

if [ "$DEEP" = 1 ]; then
  stage "port scan"
  if have naabu; then
    # naabu takes bare hosts — it fatals on "https://" prefixed targets.
    sed 's#^https\?://##; s#[/:].*$##' live.txt | sort -u > hosts.txt
    # -s connect: the default SYN scan needs raw sockets and silently
    # returns nothing on a restricted VM.
    run "naabu" naabu -l hosts.txt -silent -s connect -p "$PORTS" -rate 1000 -o ports.txt
    n=$(grep -c . ports.txt 2>/dev/null || true); ok "${n:-0} open ports"
  else
    warn "naabu missing — skipping port scan"
  fi
fi

# ──────────────────── 4. interesting endpoints ────────────────────

stage "ranking interesting endpoints"
grep -Eiv '\.(png|jpe?g|gif|svg|webp|ico|woff2?|ttf|eot|css|map)$' urls.txt \
  | grep -Ei 'api|auth|admin|user|account|login|token|oauth|graphql|debug|internal|upload|export|redirect|callback' \
  > interesting.txt 2>/dev/null || : > interesting.txt
ok "$(wc -l < interesting.txt | tr -d ' ') high-signal paths"

# ────────────────────────── 5. fuzzing ────────────────────────────

stage "content fuzzing"
# ffuf has no -l flag and no multi-host mode. Fuzz each live host in turn.
if have ffuf; then
  : > ffuf.json
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    slug=$(printf '%s' "$host" | sed 's#https\?://##; s#[/:]#_#g')
    log "ffuf → $host"
    rec=""; [ "$DEEP" = 1 ] && rec="-recursion -recursion-depth 2"
    # shellcheck disable=SC2086
    ffuf -u "$host/FUZZ" -w "$WL_CONTENT" \
         -mc 200,204,301,302,307,401,403 -ac -s \
         -rate "$RATE" -t "$THREADS" -timeout 10 $rec \
         -of json -o "ffuf_$slug.json" >/dev/null 2>&1 \
      || warn "ffuf found nothing on $host"
  done < live.txt
  # ffuf's JSON has no "url" key — results live under .results[]. Count those.
  hits=$(jq -s '[.[].results[]?] | length' ffuf_*.json 2>/dev/null || echo 0)
  jq -s '[.[].results[]?] | {results: .}' ffuf_*.json > ffuf.json 2>/dev/null \
    || cat ffuf_*.json > ffuf.json 2>/dev/null || true
  ok "${hits:-0} fuzz hits"
fi

# ───────────────────── 6. vulnerability scan ──────────────────────

stage "vulnerability scan"
# -t takes real template paths. "auth" and "misconfig" do not exist; the
# directory is http/misconfiguration. One bad entry aborts the whole run.
if have nuclei; then
  run "nuclei" nuclei -l live.txt \
    -t http/exposures -t http/misconfiguration -t http/default-logins \
    -t http/takeovers -t http/cves -t http/vulnerabilities \
    -severity medium,high,critical -silent -o nuclei.txt
fi
ok "$(grep -c . nuclei.txt 2>/dev/null || true) findings"

# ──────────────────────── 7. screenshots ──────────────────────────

stage "screenshots"
if have gowitness; then
  if [ -n "$CHROME" ]; then
    mkdir -p screenshots
    # -q keeps the banner out; --driver gorod is the one that works here.
    run "gowitness" gowitness scan file -f live.txt \
      --screenshot-path screenshots --write-jsonl --write-jsonl-file gowitness.jsonl \
      --driver gorod --chrome-path "$CHROME" -q
    shots=$(find screenshots -type f \( -name '*.jpeg' -o -name '*.png' \) 2>/dev/null | wc -l)
    ok "${shots:-0} screenshots"
  else
    warn "no chromium binary — skipping screenshots"
  fi
else
  warn "gowitness missing — skipping screenshots (go install github.com/sensepost/gowitness@latest)"
fi

# ───────────────────── 8. javascript analysis ─────────────────────

stage "javascript analysis"
grep -Ei '\.js(\?|$)' urls.txt | sort -u > js.txt 2>/dev/null || : > js.txt
ok "$(wc -l < js.txt | tr -d ' ') script files"

# ──────────────────────── 9. idor candidates ──────────────────────

stage "idor candidates"
# Case matters: real apps emit "productId", not "id".
grep -Ei '[?&](id|uid|user_?id|account_?id|pid|order_?id|doc_?id|num|no|key|ref)=' urls.txt \
  | sort -u > idor_candidates.txt 2>/dev/null || : > idor_candidates.txt
ok "$(wc -l < idor_candidates.txt | tr -d ' ') parameterised candidates"

# ──────────────────────────── summary ─────────────────────────────

ELAPSED=$(( $(date +%s) - START_TS ))
[ -s nuclei.txt ] && NUC_COLOR="$C_ERR" || NUC_COLOR="$C_OK"

printf '\n'
rule
printf '%s  SUMMARY%s   %s%s%s\n' "$C_BOLD" "$C_OFF" "$C_DIM" "$TARGET" "$C_OFF"
rule

row() {
  local label="$1" file="$2" colour="${3:-$C_OFF}"
  local n=0
  # grep -c prints "0" AND exits 1 on an empty file — a bare `|| echo 0`
  # appends a second "0" and the row renders on two lines.
  if [ -d "$file" ]; then
    n=$(find "$file" -type f 2>/dev/null | wc -l)
  elif [ -f "$file" ]; then
    n=$(grep -c . "$file" 2>/dev/null || true)
  fi
  [ -z "$n" ] && n=0
  printf '  %-22s %s%6s%s  %s%s%s\n' "$label" "$colour" "$n" "$C_OFF" "$C_DIM" "$file" "$C_OFF"
}

row "subdomains"     subs.txt
row "live hosts"     live.txt
[ "$DEEP" = 1 ] && row "open ports" ports.txt
row "endpoints"      urls.txt
row "interesting"    interesting.txt
row "screenshots"    screenshots
row "javascript"     js.txt
row "idor candidates" idor_candidates.txt
row "nuclei findings" nuclei.txt "$NUC_COLOR"

printf '\n'
printf '  %scompleted in %ss%s\n' "$C_DIM" "$ELAPSED" "$C_OFF"
printf '  %sresults →%s %s%s/%s\n\n' "$C_DIM" "$C_OFF" "$C_BOLD" "$OUT" "$C_OFF"
printf '  %sAutomation finds. You exploit.%s\n\n' "$C_DIM" "$C_OFF"
