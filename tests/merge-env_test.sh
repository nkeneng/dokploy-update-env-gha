#!/usr/bin/env bash
# Tests for merge-env.sh. Uses a fake `curl` on PATH that serves a canned GET
# response and records every argv plus the POST body. No network access.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/merge-env.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failures=0
passes=0

pass() { passes=$((passes + 1)); printf 'ok   - %s\n' "$1"; }
fail() { failures=$((failures + 1)); printf 'FAIL - %s\n' "$1"; }

# --- fake curl ---------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Records argv (one call per line, args separated by \x1f) and serves canned data.
{
  first=1
  for a in "$@"; do
    if [ "$first" = 1 ]; then first=0; else printf '\037'; fi
    printf '%s' "$a"
  done
  printf '\n'
} >> "$FAKE_CURL_ARGV"

method="GET"; out=""; data=""; has_data=0; write_out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--request) method="$2"; shift 2 ;;
    -o|--output) out="$2"; shift 2 ;;
    -w|--write-out) write_out="$2"; shift 2 ;;
    -d|--data|--data-binary|--data-raw) data="$2"; has_data=1; shift 2 ;;
    -H|--header|--connect-timeout|--max-time|-u|--user) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ "$has_data" = 1 ] && [ "$method" = "GET" ] && method="POST"
printf '%s %s\n' "$method" "$url" >> "$FAKE_CURL_REQS"

if [ "$method" = "POST" ]; then
  if [ "${data:0:1}" = "@" ]; then cat -- "${data:1}" > "$FAKE_POST_BODY"
  else printf '%s' "$data" > "$FAKE_POST_BODY"; fi
  body='{}'
  if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
else
  if [ -n "$out" ]; then cat -- "$FAKE_GET_RESPONSE" > "$out"; else cat -- "$FAKE_GET_RESPONSE"; fi
fi
if [ -n "$write_out" ]; then printf '%s' "${write_out//%\{http_code\}/200}"; fi
exit 0
FAKE
chmod +x "$WORK/bin/curl"

AUTH_PASS="HTPASS_9c2e"
API_KEY="APIKEY_SENTINEL_77d1"

# run_case <name> <resource_type> <env-string-file> <env_name> <env_value>
# Sets: RC, OUT (combined stdout+stderr file), BODY (posted JSON file), REQS, ARGV
run_case() {
  local name="$1" rtype="$2" envfile="$3" ename="$4" evalue="$5"
  local d="$WORK/$name"
  mkdir -p "$d"
  jq -n --rawfile env "$envfile" '{projectId:"p1", name:"x", env:$env}' > "$d/get.json"
  : > "$d/argv"; : > "$d/reqs"; rm -f "$d/body"
  PATH="$WORK/bin:$PATH" \
  FAKE_CURL_ARGV="$d/argv" FAKE_CURL_REQS="$d/reqs" \
  FAKE_GET_RESPONSE="$d/get.json" FAKE_POST_BODY="$d/body" \
  DOKPLOY_URL="https://u:${AUTH_PASS}@host" \
  DOKPLOY_API_KEY="$API_KEY" \
  DOKPLOY_RESOURCE_TYPE="$rtype" \
  DOKPLOY_RESOURCE_ID="res-123" \
  ENV_NAME="$ename" ENV_VALUE="$evalue" \
    bash "$SCRIPT" > "$d/out" 2>&1
  RC=$?
  OUT="$d/out"; BODY="$d/body"; REQS="$d/reqs"; ARGV="$d/argv"
}

posted_env() { jq -j '.env' "$BODY" 2>/dev/null; }

# --- fixture env -------------------------------------------------------------
ENV1="$WORK/env1"
printf '%s' $'FIRST=SECRET_VALUE_5a1b\nCRLF_KEY=SECRET_CRLF_3f9a\r\n\n  SPACED=SECRET_SPACED_8e2d  \nTARGET=SECRET_OLD_1c4f\nQUOTED="SECRET_Q_6b7e=with=equals"\nTARGET_SUFFIX=SECRET_SUFFIX_2d8c\nLAST=SECRET_LAST_4a0b\n' > "$ENV1"
NEW_VALUE="SECRET_NEW_9f3e"

# 1. Replace in place --------------------------------------------------------
run_case replace project "$ENV1" TARGET "$NEW_VALUE"
expected=$'FIRST=SECRET_VALUE_5a1b\nCRLF_KEY=SECRET_CRLF_3f9a\r\n\n  SPACED=SECRET_SPACED_8e2d  \nTARGET=SECRET_NEW_9f3e\nQUOTED="SECRET_Q_6b7e=with=equals"\nTARGET_SUFFIX=SECRET_SUFFIX_2d8c\nLAST=SECRET_LAST_4a0b\n'
if [ "$RC" = 0 ] && [ -f "$BODY" ] && [ "$(posted_env; printf x)" = "${expected}x" ]; then
  pass "replace in place keeps every other line byte-identical"
else
  fail "replace in place keeps every other line byte-identical (rc=$RC)"
fi
if [ "$(jq -r '.projectId' "$BODY" 2>/dev/null)" = "res-123" ]; then
  pass "update payload carries projectId"
else
  fail "update payload carries projectId"
fi
if grep -qxF "Merged env var 'TARGET' into Dokploy project res-123" "$OUT"; then
  pass "prints the exact success line"
else
  fail "prints the exact success line"
fi

# 2. Leak check (on the replace run) -----------------------------------------
leaked=0
for s in SECRET_VALUE_5a1b SECRET_CRLF_3f9a SECRET_SPACED_8e2d SECRET_OLD_1c4f \
         SECRET_Q_6b7e SECRET_SUFFIX_2d8c SECRET_LAST_4a0b "$NEW_VALUE" \
         "$AUTH_PASS" "$API_KEY"; do
  if grep -qF -- "$s" "$OUT"; then leaked=1; fi
done
if [ "$leaked" = 0 ]; then pass "no env value, auth password or API key in output"
else fail "no env value, auth password or API key in output"; fi

# 3. Append, env with final newline ------------------------------------------
run_case append_nl project "$ENV1" NEWKEY "$NEW_VALUE"
expected="$(cat "$ENV1"; printf 'NEWKEY=%s\n' "$NEW_VALUE"; printf x)"
if [ "$RC" = 0 ] && [ "$(posted_env; printf x)" = "$expected" ]; then
  pass "append to env ending in newline"
else
  fail "append to env ending in newline (rc=$RC)"
fi

# 4. Append, env without final newline ---------------------------------------
ENV2="$WORK/env2"
printf '%s' $'A=SECRET_VALUE_5a1b\nB=SECRET_LAST_4a0b' > "$ENV2"
run_case append_nonl project "$ENV2" NEWKEY "$NEW_VALUE"
expected=$'A=SECRET_VALUE_5a1b\nB=SECRET_LAST_4a0b\nNEWKEY=SECRET_NEW_9f3e'
if [ "$RC" = 0 ] && [ "$(posted_env; printf x)" = "${expected}x" ]; then
  pass "append adds a newline first when env lacks one"
else
  fail "append adds a newline first when env lacks one (rc=$RC)"
fi

# 5. Append to empty env ------------------------------------------------------
ENV3="$WORK/env3"; : > "$ENV3"
run_case append_empty project "$ENV3" NEWKEY "$NEW_VALUE"
if [ "$RC" = 0 ] && [ "$(posted_env; printf x)" = "NEWKEY=${NEW_VALUE}x" ]; then
  pass "append to empty env"
else
  fail "append to empty env (rc=$RC)"
fi

# 6. Timeouts on every curl call ---------------------------------------------
run_case timeouts project "$ENV1" TARGET "$NEW_VALUE"
calls=$(wc -l < "$ARGV" | tr -d ' ')
bad=0
while IFS= read -r line; do
  case "$line" in *$'\037'--connect-timeout$'\037'*) ;; *) bad=1 ;; esac
  case "$line" in *$'\037'--max-time$'\037'*) ;; *) bad=1 ;; esac
done < "$ARGV"
if [ "$calls" -ge 2 ] && [ "$bad" = 0 ]; then pass "every curl call has --connect-timeout and --max-time"
else fail "every curl call has --connect-timeout and --max-time"; fi

# 7. Duplicate key -----------------------------------------------------------
ENV4="$WORK/env4"
printf '%s' $'DUP=SECRET_VALUE_5a1b\nOTHER=x\nDUP=SECRET_LAST_4a0b\n' > "$ENV4"
run_case dup project "$ENV4" DUP "$NEW_VALUE"
if [ "$RC" != 0 ] && grep -qi "duplicate key" "$OUT" && [ ! -f "$BODY" ] \
   && ! grep -qF SECRET_VALUE_5a1b "$OUT"; then
  pass "duplicate key fails without posting"
else
  fail "duplicate key fails without posting (rc=$RC)"
fi

# 8. Resource types hit the right endpoints ----------------------------------
for spec in project:projectId compose:composeId application:applicationId; do
  rtype="${spec%%:*}"; idkey="${spec#*:}"
  run_case "type_$rtype" "$rtype" "$ENV1" TARGET "$NEW_VALUE"
  get_ok=0; post_ok=0
  grep -qxF "GET https://u:${AUTH_PASS}@host/api/${rtype}.one?${idkey}=res-123" "$REQS" && get_ok=1
  grep -qxF "POST https://u:${AUTH_PASS}@host/api/${rtype}.update" "$REQS" && post_ok=1
  if [ "$RC" = 0 ] && [ "$get_ok" = 1 ] && [ "$post_ok" = 1 ] \
     && [ "$(jq -r --arg k "$idkey" '.[$k]' "$BODY" 2>/dev/null)" = "res-123" ]; then
    pass "resource type $rtype uses $rtype.one / $rtype.update with $idkey"
  else
    fail "resource type $rtype uses $rtype.one / $rtype.update with $idkey (rc=$RC)"
  fi
done

printf '\n%d passed, %d failed\n' "$passes" "$failures"
[ "$failures" = 0 ]
