#!/usr/bin/env bash
###############################################################################
# personalize.sh
#
# Cold-email lead personalizer.
#
# INPUT can be either:
#   - a local CSV file, OR
#   - a PUBLIC Google Sheet URL (shared "Anyone with the link = Viewer").
#     The script downloads it as CSV via the /export endpoint (no auth).
#
# For EACH lead (one at a time, sequentially):
#   1. Fetches + cleans the article LOCALLY via fetch_article.py (a wrapper
#      around the provided agent_fetch.py).
#   2. Calls the opencode CLI, triggering the skill via its slash command
#      "/personalize-cold-email" with the lead data + cleaned article_content
#      right after it (one message).
#   3. Validates the returned JSON, then saves the lead (original columns +
#      first_name + topic) to the output sink(s):
#        - always to a local CSV (this is the resume ledger + audit trail), and
#        - additionally to a NOTION database when NOTION_TOKEN + NOTION_DB_ID
#          are set (via the Notion REST API + curl).
#
# Features:
#   - Sequential, one lead at a time (waits for each opencode reply)
#   - Resumable: skips leads already saved (matched on email). Reads the local
#     CSV ledger, and (if Notion is on) also pre-loads existing emails from the
#     Notion DB so a lost CSV won't create duplicate Notion pages.
#   - Validates the returned JSON has all 7 expected keys
#   - Routes bad/empty JSON to failed.log, INSUFFICIENT/FETCH_FAILED to review.log,
#     and Notion API failures to notion.log (those leads are retried next run)
#   - SPEED: server mode (USE_SERVER=1, default) starts ONE warm opencode server
#     and attaches every call to it, so the cold-boot is paid once, not per lead.
#     Falls back to per-call mode automatically if the server can't start.
#   - Prints per-lead timing [fetch Xms, model Yms] so you can see where time goes
#   - 3-second pause between calls
#   - Progress printout
#
# Requirements (pre-installed on the Ubuntu VM):
#   - opencode  (with the "personalize-cold-email" skill installed)
#   - jq        (JSON parsing + building Notion request bodies)
#   - gawk      (robust CSV field parsing via FPAT; Ubuntu's default mawk lacks it)
#   - python3   (runs fetch_article.py -> agent_fetch.py)
#   - curl      (Google Sheet download + Notion API)
#               install with:  sudo apt-get install -y gawk jq python3 curl
#
# Files that must sit together in the same directory:
#   personalize.sh  fetch_article.py  agent_fetch.py  http_utils.py
#   (http_utils.py is a dependency of agent_fetch.py from your aienrich project.)
#
# NOTION SETUP (only if you want Notion output):
#   1. Create an internal integration -> https://www.notion.so/my-integrations
#      Copy its secret. Export it as NOTION_TOKEN.
#   2. Create the target database (an EMPTY one is fine), "..." menu ->
#      Connections -> add your integration so it has write access. Use its URL
#      at the prompt (the script extracts the id), or export NOTION_DB_ID.
#   3. You do NOT need to create columns by hand. On startup the script
#      auto-creates any missing fields (NOTION_AUTO_SCHEMA=1, the default) and
#      auto-detects the Title column (a new DB calls it "Name"). It only ADDS
#      columns, never renames/deletes. The fields it ensures exist:
#        <title col> <- full_name   (auto-detected, e.g. "Name")
#        first_name -> Text     topic   -> Text     role    -> Text
#        company    -> Text     revenue -> Text      status  -> Select
#        email      -> Email    article_url -> URL   linkedin -> URL
#      (Set NOTION_AUTO_SCHEMA=0 to manage the columns yourself instead.)
#
# Usage:
#   chmod +x personalize.sh
#   ./personalize.sh        # interactive: prompts for the leads source, Notion
#                           # token (hidden), and Notion database URL.
#
#   Or skip the prompts by passing everything as env vars (these always win):
#   IN="https://docs.google.com/spreadsheets/d/<ID>/edit#gid=0" \
#     NOTION_TOKEN=secret_xxx NOTION_DB_ID=abc123... ./personalize.sh
#
#   NO_PROMPT=1 ./personalize.sh    # never prompt (for cron/automation)
#   LIMIT=10 ./personalize.sh       # process only the first 10 leads (testing)
#   USE_SERVER=0 ./personalize.sh   # disable warm server (cold-boot each lead)
#   SERVER_PORT=4097 ./personalize.sh   # use a different server port
###############################################################################

set -uo pipefail   # -e is intentionally OFF: we expect some commands (jq checks,
                   # opencode calls) to fail per-lead and we handle that ourselves.

# ---------------------------------------------------------------------------
# Config — override any of these by setting them in the environment.
# ---------------------------------------------------------------------------
IN="${IN:-leads.csv}"                          # input CSV
OUT="${OUT:-leads_personalized.csv}"           # output CSV (also the resume source)
FAILED_LOG="${FAILED_LOG:-failed.log}"         # invalid / unparseable JSON
REVIEW_LOG="${REVIEW_LOG:-review.log}"         # topic == INSUFFICIENT / FETCH_FAILED
ERR_LOG="${ERR_LOG:-opencode_stderr.log}"      # opencode's own stderr chatter
SLEEP_SECS="${SLEEP_SECS:-3}"                  # pause between calls
LIMIT="${LIMIT:-0}"                            # process only first N leads (0 = all). For testing.
MODEL="${MODEL:-}"                             # optional, e.g. anthropic/claude-sonnet-4
PYTHON="${PYTHON:-python3}"                     # python interpreter
FETCH_SCRIPT="${FETCH_SCRIPT:-fetch_article.py}"  # local article fetcher (CLI wrapper)

# --- Server mode (speed) — keep ONE opencode runtime warm and attach each call.
# Avoids re-booting opencode for every lead. Each call still gets a fresh
# session (no context bleed); only the cold-start is amortized to once.
USE_SERVER="${USE_SERVER:-1}"                  # 1 = start/attach a warm server
SERVER_HOST="${SERVER_HOST:-127.0.0.1}"        # opencode serve --hostname
SERVER_PORT="${SERVER_PORT:-4096}"             # opencode serve --port
SERVER_URL="http://${SERVER_HOST}:${SERVER_PORT}"
SERVER_PID=""                                  # set only if WE start it (so we only stop ours)

# --- Notion output (optional) — enabled only when token + DB id are both set ---
NOTION_TOKEN="${NOTION_TOKEN:-}"               # internal integration secret
NOTION_DB_ID="${NOTION_DB_ID:-}"               # target database id
NOTION_VERSION="${NOTION_VERSION:-2022-06-28}" # Notion-Version header
NOTION_TITLE_PROP="${NOTION_TITLE_PROP:-full_name}"  # name of the DB's Title property
NOTION_LOG="${NOTION_LOG:-notion.log}"         # Notion API failures
NOTION_PRELOAD="${NOTION_PRELOAD:-1}"          # 1 = pull existing emails from DB at start
NOTION_AUTO_SCHEMA="${NOTION_AUTO_SCHEMA:-1}"  # 1 = auto-create missing DB fields at start

# Extract a Notion database id from a pasted database URL (or accept a raw id).
# Notion URLs look like  .../Some-Page-Title-<32hexid>?v=<view>  so the id is
# the last dash-separated token; "Copy link" can also give a dashed UUID.
extract_notion_db_id() {
  local raw="${1%%\?*}" uuid base seg     # drop any ?v=... query string first
  # 1) a dashed UUID (8-4-4-4-12) anywhere -> strip dashes
  uuid="$(printf '%s' "$raw" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n 1)"
  if [[ -n "$uuid" ]]; then
    printf '%s' "${uuid//-/}"
    return
  fi
  base="${raw##*/}"                        # last path segment
  seg="${base##*-}"                        # token after the last dash
  if [[ "$seg" =~ ^[0-9a-fA-F]{32}$ ]]; then printf '%s' "$seg"; return; fi
  if [[ "$base" =~ ^[0-9a-fA-F]{32}$ ]]; then printf '%s' "$base"; return; fi
  printf ''                                # nothing usable found
}

# ---------------------------------------------------------------------------
# Interactive prompts — only when running in a terminal and the value wasn't
# already supplied via an env var. Set NO_PROMPT=1 to disable (cron/automation).
# Env vars always take precedence; just press Enter to accept a shown default.
# ---------------------------------------------------------------------------
if [[ -t 0 && "${NO_PROMPT:-0}" != "1" ]]; then
  echo "=== Setup (press Enter to accept the [default], or type a new value) ==="

  # Leads source: public Google Sheet URL or local CSV path.
  read -r -p "Leads source — Google Sheet URL or CSV path [${IN}]: " _in
  [[ -n "${_in:-}" ]] && IN="$_in"

  # Model: type a provider/model id to override, or leave blank to use the
  # model you've selected inside opencode (its /models default).
  read -r -p "Model id (provider/model) — blank = opencode's selected default [${MODEL:-opencode default}]: " _model
  [[ -n "${_model:-}" ]] && MODEL="$_model"

  # Notion token (optional). Hidden input so it isn't shown on screen.
  if [[ -z "$NOTION_TOKEN" ]]; then
    read -r -s -p "Notion token (hidden — leave blank to save to CSV only): " _tok
    echo
    [[ -n "${_tok:-}" ]] && NOTION_TOKEN="$_tok"
  fi

  # Notion database URL -> id (only asked if a token was given).
  if [[ -n "$NOTION_TOKEN" && -z "$NOTION_DB_ID" ]]; then
    read -r -p "Notion database URL (or id): " _dburl
    if [[ -n "${_dburl:-}" ]]; then
      NOTION_DB_ID="$(extract_notion_db_id "$_dburl")"
      if [[ -z "$NOTION_DB_ID" ]]; then
        echo "WARN: couldn't find a 32-char id in that input — Notion will be OFF." >&2
      else
        echo "  parsed Notion DB id: $NOTION_DB_ID"
      fi
    fi
  fi
  echo
fi

# Enable Notion only if BOTH a token and a db id ended up set.
USE_NOTION=0
[[ -n "$NOTION_TOKEN" && -n "$NOTION_DB_ID" ]] && USE_NOTION=1

# Output header = original 8 columns + the 2 new ones.
OUT_HEADER="full_name,article_url,role,company,linkedin,email,revenue,status,first_name,topic"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
for cmd in opencode jq gawk curl "$PYTHON"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# If IN is a PUBLIC Google Sheet URL, download it as CSV to a temp file.
# Works for sheets shared "Anyone with the link = Viewer" (no auth). Private
# sheets will fail here with a clear message.
# ---------------------------------------------------------------------------
if [[ "$IN" == *docs.google.com/spreadsheets* ]]; then
  sheet_id="$(printf '%s' "$IN" | sed -n 's#.*/spreadsheets/d/\([a-zA-Z0-9_-]\{20,\}\).*#\1#p')"
  sheet_gid="$(printf '%s' "$IN" | sed -n 's#.*[?#&]gid=\([0-9]\{1,\}\).*#\1#p')"
  if [[ -z "$sheet_id" ]]; then
    echo "ERROR: could not parse the Google Sheet id from IN." >&2
    exit 1
  fi
  export_url="https://docs.google.com/spreadsheets/d/${sheet_id}/export?format=csv"
  [[ -n "$sheet_gid" ]] && export_url="${export_url}&gid=${sheet_gid}"

  tmp_csv="$(mktemp "${TMPDIR:-/tmp}/leads.XXXXXX.csv")"
  echo "Downloading public Google Sheet -> $tmp_csv"
  if ! curl -fsSL "$export_url" -o "$tmp_csv"; then
    echo "ERROR: could not download the sheet as CSV." >&2
    echo "       Make sure it is shared 'Anyone with the link = Viewer' (or published)." >&2
    exit 1
  fi
  # A private sheet returns an HTML sign-in page instead of CSV — detect that.
  if head -c 200 "$tmp_csv" | grep -qiE '<!DOCTYPE|<html'; then
    echo "ERROR: the sheet didn't return CSV (looks like an HTML/sign-in page)." >&2
    echo "       Make sure it's shared 'Anyone with the link = Viewer' (or published)." >&2
    exit 1
  fi
  if [[ ! -s "$tmp_csv" ]]; then
    echo "ERROR: the downloaded sheet CSV is empty." >&2
    exit 1
  fi
  IN="$tmp_csv"
fi

if [[ ! -f "$IN" ]]; then
  echo "ERROR: input file '$IN' not found." >&2
  exit 1
fi

if [[ ! -f "$FETCH_SCRIPT" ]]; then
  echo "ERROR: fetch script '$FETCH_SCRIPT' not found." >&2
  exit 1
fi

if (( USE_NOTION )); then
  echo "Notion output: ON (db=$NOTION_DB_ID, title prop='$NOTION_TITLE_PROP')."
else
  echo "Notion output: OFF (set NOTION_TOKEN + NOTION_DB_ID to enable)."
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Split one CSV line into fields (handles quoted fields containing commas).
# Prints one field per line. NOTE: assumes no embedded newlines inside fields.
parse_csv_line() {
  gawk -v FPAT='([^,]*)|("([^"]|"")*")' '{ for (i = 1; i <= NF; i++) print $i }' <<< "$1"
}

# Remove surrounding double quotes and un-double internal quotes ("" -> ").
unquote() {
  local s="$1"
  if [[ "$s" == \"*\" ]]; then
    s="${s#\"}"
    s="${s%\"}"
    s="${s//\"\"/\"}"
  fi
  printf '%s' "$s"
}

# Quote a value for CSV output if it contains a comma, quote, or newline.
csv_escape() {
  local s="$1"
  if [[ "$s" == *,* || "$s" == *\"* || "$s" == *$'\n'* ]]; then
    s="${s//\"/\"\"}"
    printf '"%s"' "$s"
  else
    printf '%s' "$s"
  fi
}

# Pull the first balanced top-level JSON object out of arbitrary text.
# Brace-counting that ignores braces inside strings and handles escapes,
# so noise printed before/after the JSON by opencode is stripped away.
extract_json() {
  gawk '
  {
    line = $0
    n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (esc) {                       # previous char was a backslash
        esc = 0
      } else if (c == "\\") {
        esc = 1
      } else if (c == "\"") {
        instr = (instr ? 0 : 1)        # toggle in/out of a string
      } else if (!instr) {
        if (c == "{") { if (depth == 0) cap = 1; depth++ }
        else if (c == "}") { depth-- }
      }
      if (cap) buf = buf c
      if (cap && !instr && depth == 0 && c == "}") { print buf; exit }
    }
    if (cap) buf = buf "\n"             # preserve newlines inside the object
  }'
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# Milliseconds since epoch (for per-lead timing). GNU date supports %3N; if not,
# fall back to whole-second resolution so the script still runs anywhere.
now_ms() {
  local n; n="$(date +%s%3N 2>/dev/null)"
  if [[ -z "$n" || "$n" == *N* ]]; then n="$(( $(date +%s) * 1000 ))"; fi
  printf '%s' "$n"
}

# True if an opencode server is answering on $SERVER_URL.
server_health_ok() { curl -fsS "$SERVER_URL/global/health" >/dev/null 2>&1; }

# Start a warm opencode server (unless one is already running we can reuse).
# Returns 0 if a healthy server is available, 1 otherwise.
start_server() {
  if server_health_ok; then
    echo "Reusing opencode server already running at $SERVER_URL."
    return 0           # not ours -> SERVER_PID stays empty -> we won't stop it
  fi
  echo "Starting opencode server at $SERVER_URL ..."
  opencode serve --hostname "$SERVER_HOST" --port "$SERVER_PORT" >>"$ERR_LOG" 2>&1 &
  SERVER_PID=$!
  local i
  for ((i = 0; i < 60; i++)); do            # wait up to ~30s
    if server_health_ok; then
      echo "Server is up (pid $SERVER_PID)."
      return 0
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then   # process died early
      echo "WARN: 'opencode serve' exited early; see $ERR_LOG." >&2
      SERVER_PID=""
      return 1
    fi
    sleep 0.5
  done
  echo "WARN: server didn't become healthy within ~30s." >&2
  return 1
}

# Stop the server, but ONLY if we were the ones who started it.
stop_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Stopping opencode server (pid $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
}

# Make sure the Notion DB has all the columns we need. Reads the current
# schema, auto-detects the real Title column name (a new DB calls it "Name"),
# and PATCHes in any missing fields with the right types. Additive only — it
# never renames or deletes existing columns, so it's safe to re-run.
notion_ensure_schema() {
  local resp title_prop add body resp2
  resp="$(curl -sS "https://api.notion.com/v1/databases/$NOTION_DB_ID" \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" 2>>"$ERR_LOG")"
  if [[ $? -ne 0 ]] || printf '%s' "$resp" | jq -e '.object == "error"' >/dev/null 2>&1; then
    echo "WARN: couldn't read Notion DB schema (is the integration shared with it?); skipping auto-setup." >&2
    printf '%s | schema_read | %s\n' "$(ts)" \
      "$(printf '%s' "$resp" | jq -c '{status, code, message}' 2>/dev/null)" >> "$NOTION_LOG"
    return 1
  fi

  # Use the database's actual Title column for full_name (don't assume a name).
  title_prop="$(printf '%s' "$resp" | jq -r '
    .properties | to_entries[] | select(.value.type == "title") | .key' | head -n 1)"
  if [[ -n "$title_prop" && "$title_prop" != "$NOTION_TITLE_PROP" ]]; then
    echo "  Title column is '$title_prop' -> mapping full_name to it."
    NOTION_TITLE_PROP="$title_prop"
  fi

  # Compute which of our required (non-title) fields are missing.
  add="$(printf '%s' "$resp" | jq '
    def want: {
      "first_name": {"rich_text":{}}, "topic":   {"rich_text":{}},
      "role":       {"rich_text":{}}, "company": {"rich_text":{}},
      "revenue":    {"rich_text":{}}, "status":  {"select":{}},
      "email":      {"email":{}},     "article_url": {"url":{}},
      "linkedin":   {"url":{}}
    };
    (.properties // {}) as $have
    | want | with_entries(select(.key as $k | ($have | has($k)) | not))')"

  if [[ "$(printf '%s' "$add" | jq 'length')" == "0" ]]; then
    echo "  Notion schema OK (all required fields present)."
    return 0
  fi

  echo "  Creating missing Notion fields: $(printf '%s' "$add" | jq -r 'keys | join(", ")')"
  body="$(jq -n --argjson props "$add" '{properties: $props}')"
  resp2="$(curl -sS -X PATCH "https://api.notion.com/v1/databases/$NOTION_DB_ID" \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    -d "$body" 2>>"$ERR_LOG")"
  if [[ $? -ne 0 ]] || printf '%s' "$resp2" | jq -e '.object == "error"' >/dev/null 2>&1; then
    echo "WARN: failed to create some Notion fields; see $NOTION_LOG." >&2
    printf '%s | schema_patch | %s\n' "$(ts)" \
      "$(printf '%s' "$resp2" | jq -c '{status, code, message}' 2>/dev/null)" >> "$NOTION_LOG"
    return 1
  fi
  echo "  Notion fields created."
  return 0
}

# Create one Notion page (row) from the current lead's variables.
# Builds the request body with jq (safe escaping) and POSTs via curl.
# Returns 0 on success; on failure logs to $NOTION_LOG and returns 1.
# Relies on: full_name first_name topic role company article_url linkedin
#            email revenue status  (set in the main loop before calling).
notion_create_page() {
  local body resp
  body="$(jq -n \
    --arg dbid  "$NOTION_DB_ID" \
    --arg tp    "$NOTION_TITLE_PROP" \
    --arg full_name "$full_name" \
    --arg first_name "$first_name" \
    --arg topic "$topic" \
    --arg role  "$role" \
    --arg company "$company" \
    --arg article_url "$article_url" \
    --arg linkedin "$linkedin" \
    --arg email "$email" \
    --arg revenue "$revenue" \
    --arg status "$status" \
    'def rt($s): { rich_text: [ { text: { content: $s } } ] };
     {
       parent: { database_id: $dbid },
       properties: (
         {
           ($tp):        { title: [ { text: { content: $full_name } } ] },
           "first_name": rt($first_name),
           "topic":      rt($topic),
           "role":       rt($role),
           "company":    rt($company),
           "revenue":    rt($revenue),
           "email":      { email: (if $email == "" then null else $email end) }
         }
         + (if $article_url != "" then { "article_url": { url: $article_url } } else {} end)
         + (if $linkedin    != "" then { "linkedin":    { url: $linkedin } }    else {} end)
         + (if $status      != "" then { "status": { select: { name: $status } } } else {} end)
       )
     }')"

  resp="$(curl -sS -X POST "https://api.notion.com/v1/pages" \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    -d "$body" 2>>"$ERR_LOG")"
  local rc=$?

  if (( rc != 0 )); then
    printf '%s | %s | curl_exit=%s\n' "$(ts)" "$email" "$rc" >> "$NOTION_LOG"
    return 1
  fi
  # Notion returns {"object":"error", "status":..., "code":..., "message":...}
  if printf '%s' "$resp" | jq -e '.object == "error"' >/dev/null 2>&1; then
    printf '%s | %s | %s\n' "$(ts)" "$email" \
      "$(printf '%s' "$resp" | jq -c '{status, code, message}')" >> "$NOTION_LOG"
    return 1
  fi
  return 0
}

# Pull every existing email from the Notion DB (paginated) into DONE, so a
# missing local CSV won't cause duplicate pages. Assumes an "email" property
# of type Email. On any query error we warn and fall back to the CSV ledger.
notion_preload_done() {
  local cursor="" has_more="true" body resp got
  while [[ "$has_more" == "true" ]]; do
    if [[ -z "$cursor" ]]; then
      body='{"page_size":100}'
    else
      body="$(jq -n --arg c "$cursor" '{page_size:100, start_cursor:$c}')"
    fi
    resp="$(curl -sS -X POST "https://api.notion.com/v1/databases/$NOTION_DB_ID/query" \
      -H "Authorization: Bearer $NOTION_TOKEN" \
      -H "Notion-Version: $NOTION_VERSION" \
      -H "Content-Type: application/json" \
      -d "$body" 2>>"$ERR_LOG")"
    if [[ $? -ne 0 ]] || printf '%s' "$resp" | jq -e '.object == "error"' >/dev/null 2>&1; then
      echo "WARN: could not query Notion for existing emails; using CSV ledger only." >&2
      return 0
    fi
    while IFS= read -r got; do
      [[ -n "$got" ]] && DONE["$got"]=1
    done < <(printf '%s' "$resp" | jq -r '.results[].properties.email.email // empty')
    has_more="$(printf '%s' "$resp" | jq -r '.has_more')"
    cursor="$(printf '%s' "$resp" | jq -r '.next_cursor // empty')"
  done
}

# ---------------------------------------------------------------------------
# Build the "already done" set from the existing output CSV (resume support).
# Match key = email.
# ---------------------------------------------------------------------------
declare -A DONE
if [[ -f "$OUT" ]]; then
  first=1
  while IFS= read -r oline || [[ -n "$oline" ]]; do
    [[ -z "$oline" ]] && continue
    if (( first )); then first=0; continue; fi      # skip header
    mapfile -t of < <(parse_csv_line "$oline")
    oemail="$(unquote "${of[5]:-}")"
    [[ -n "$oemail" ]] && DONE["$oemail"]=1
  done < "$OUT"
fi

# Make sure the Notion DB has the columns we need (creates missing ones).
# Off by setting NOTION_AUTO_SCHEMA=0.
if (( USE_NOTION )) && [[ "$NOTION_AUTO_SCHEMA" == "1" ]]; then
  echo "Checking Notion database schema..."
  notion_ensure_schema
fi

# Also pre-load already-saved emails from Notion (guards against duplicate pages
# if the local CSV ledger was lost). Off by setting NOTION_PRELOAD=0.
if (( USE_NOTION )) && [[ "$NOTION_PRELOAD" == "1" ]]; then
  echo "Pre-loading existing emails from Notion..."
  notion_preload_done
fi

# Create the output file with a header if it doesn't exist yet.
if [[ ! -f "$OUT" ]]; then
  printf '%s\n' "$OUT_HEADER" > "$OUT"
fi

# Total number of data rows (for progress). Assumes no embedded newlines.
TOTAL="$(gawk 'NR>1{c++} END{print c+0}' "$IN")"

# Start a warm server once (speed). Always shut down ours on exit/Ctrl-C.
# If it can't start, fall back to per-call (cold-boot) mode.
if (( USE_SERVER )); then
  trap stop_server EXIT INT TERM
  if ! start_server; then
    echo "Falling back to per-call mode (each lead cold-boots opencode)."
    USE_SERVER=0
  fi
fi

echo "Starting. $TOTAL leads in '$IN'. Already done: ${#DONE[@]}."
echo "Model: ${MODEL:-<opencode selected default>}"
echo "Server mode: $( (( USE_SERVER )) && echo "ON ($SERVER_URL)" || echo "OFF (per-call boot)")"
echo "-------------------------------------------------------------"

# ---------------------------------------------------------------------------
# Main loop — one lead at a time.
# ---------------------------------------------------------------------------
idx=0
first=1
# Read the CSV on file descriptor 3 (not stdin), so commands inside the loop
# (notably `opencode`) can't consume the lead list out from under us.
while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
  [[ -z "$line" ]] && continue
  if (( first )); then first=0; continue; fi        # skip header row
  idx=$((idx + 1))

  # Stop early when testing on a subset (LIMIT>0).
  if (( LIMIT > 0 )) && (( idx > LIMIT )); then
    echo "Reached LIMIT=$LIMIT lead(s); stopping."
    break
  fi

  # --- parse the row into named variables -----------------------------------
  mapfile -t f < <(parse_csv_line "$line")
  full_name="$(unquote "${f[0]:-}")"
  article_url="$(unquote "${f[1]:-}")"
  role="$(unquote "${f[2]:-}")"
  company="$(unquote "${f[3]:-}")"
  linkedin="$(unquote "${f[4]:-}")"
  email="$(unquote "${f[5]:-}")"
  revenue="$(unquote "${f[6]:-}")"
  status="$(unquote "${f[7]:-}")"

  # --- resume: skip if we've already processed this email -------------------
  if [[ -n "${DONE[$email]:-}" ]]; then
    echo "[$idx/$TOTAL] Skip (already done): $email"
    continue
  fi

  echo "[$idx/$TOTAL] Processing: ${full_name:-<no name>} <$email>"
  fetch_ms=0; model_ms=0       # per-lead timers (reset each iteration)

  # --- fetch + clean the article LOCALLY ------------------------------------
  # A failed/empty local fetch goes to review.log as FETCH_FAILED, and we skip
  # the opencode call entirely (no point spending tokens on empty content).
  if [[ -z "$article_url" ]]; then
    echo "  -> no article_url; logged to $REVIEW_LOG"
    printf '%s | %s | FETCH_FAILED | empty_article_url\n' "$(ts)" "$email" >> "$REVIEW_LOG"
    continue
  fi

  _t0="$(now_ms)"
  article_content="$("$PYTHON" "$FETCH_SCRIPT" "$article_url" 2>>"$ERR_LOG")"
  fetch_status=$?
  fetch_ms=$(( $(now_ms) - _t0 ))
  if (( fetch_status != 0 )); then
    echo "  -> article fetch failed (exit $fetch_status, ${fetch_ms}ms); logged to $REVIEW_LOG"
    printf '%s | %s | FETCH_FAILED | fetch_exit=%s | %s\n' \
      "$(ts)" "$email" "$fetch_status" "$article_url" >> "$REVIEW_LOG"
    continue
  fi

  # --- build the prompt for the skill ---------------------------------------
  # Trigger the skill via its slash command, with the lead data right after it
  # (same message), exactly as you'd type it by hand in opencode.
  PROMPT="$(printf '/personalize-cold-email\n\nfull_name: %s\narticle_url: %s\nlinkedin: %s\nemail: %s\narticle_content: %s\n' \
            "$full_name" "$article_url" "$linkedin" "$email" "$article_content")"

  # --- call opencode (waits here until it replies) --------------------------
  # Server mode: --attach reuses the warm runtime; still a fresh session per lead.
  OC_ARGS=(run)
  [[ -n "$MODEL" ]] && OC_ARGS+=(--model "$MODEL")
  (( USE_SERVER )) && OC_ARGS+=(--attach "$SERVER_URL")
  _t1="$(now_ms)"
  raw_output="$(opencode "${OC_ARGS[@]}" "$PROMPT" </dev/null 2>>"$ERR_LOG")"
  oc_status=$?
  model_ms=$(( $(now_ms) - _t1 ))

  # Pause between calls (counts as "between calls" regardless of outcome).
  sleep "$SLEEP_SECS"

  if (( oc_status != 0 )); then
    echo "  -> opencode exited with status $oc_status; logged to $FAILED_LOG"
    printf '%s | %s | opencode_exit=%s\n' "$(ts)" "$email" "$oc_status" >> "$FAILED_LOG"
    continue
  fi

  # --- extract + validate JSON ----------------------------------------------
  json="$(printf '%s\n' "$raw_output" | extract_json)"

  if [[ -z "$json" ]]; then
    echo "  -> no JSON found in output; logged to $FAILED_LOG"
    { printf '%s | %s | no_json_in_output\n' "$(ts)" "$email"
      printf '    raw: %s\n' "$(printf '%s' "$raw_output" | head -c 500 | tr '\n' ' ')"
    } >> "$FAILED_LOG"
    continue
  fi

  # All 7 required keys must be present.
  if ! printf '%s' "$json" | jq -e '
        has("full_name") and has("first_name") and has("topic") and
        has("role") and has("article_url") and has("linkedin") and has("email")
      ' >/dev/null 2>&1; then
    echo "  -> JSON missing required keys; logged to $FAILED_LOG"
    { printf '%s | %s | missing_keys\n' "$(ts)" "$email"
      printf '    json: %s\n' "$(printf '%s' "$json" | tr '\n' ' ')"
    } >> "$FAILED_LOG"
    continue
  fi

  # --- pull the values we need ----------------------------------------------
  topic="$(printf '%s' "$json" | jq -r '.topic')"
  first_name="$(printf '%s' "$json" | jq -r '.first_name')"

  # --- route skill "soft failures" to review.log ----------------------------
  if [[ "$topic" == "INSUFFICIENT" || "$topic" == "FETCH_FAILED" ]]; then
    echo "  -> topic=$topic; logged to $REVIEW_LOG"
    printf '%s | %s | %s | %s\n' "$(ts)" "$email" "$topic" "$article_url" >> "$REVIEW_LOG"
    continue
  fi

  # --- save the result ------------------------------------------------------
  # When Notion is on, push there FIRST. If Notion fails, we do NOT write the
  # CSV ledger or mark done, so the lead is retried on the next run.
  if (( USE_NOTION )); then
    if ! notion_create_page; then
      echo "  -> Notion write failed; logged to $NOTION_LOG (will retry next run)"
      continue
    fi
  fi

  # Append to the local CSV ledger (original 8 cols + first_name + topic).
  row=""
  for v in "$full_name" "$article_url" "$role" "$company" \
           "$linkedin" "$email" "$revenue" "$status" "$first_name" "$topic"; do
    row+="$(csv_escape "$v"),"
  done
  row="${row%,}"                      # drop trailing comma
  printf '%s\n' "$row" >> "$OUT"
  DONE["$email"]=1                    # mark done (handles duplicate rows too)

  echo "  -> OK: first_name='$first_name', topic='$topic'$( (( USE_NOTION )) && printf ' (saved to Notion)') [fetch ${fetch_ms}ms, model ${model_ms}ms]"
  echo "Processed $idx of $TOTAL leads"
done 3< "$IN"

echo "-------------------------------------------------------------"
echo "Done. CSV ledger: $OUT$( (( USE_NOTION )) && printf '  |  Notion DB: %s' "$NOTION_DB_ID")"
echo "Check '$FAILED_LOG' and '$REVIEW_LOG' for skipped leads$( (( USE_NOTION )) && printf ", and '%s' for Notion errors" "$NOTION_LOG")."
