#!/usr/bin/env bash
# Smoke test for ../kernel.R
#
#   ./kernel_test.sh
#
# Starts the kernel on a random port with a random token, exercises the whole
# HTTP API with curl and checks the results.  Prints one line per check and
# exits non-zero if anything failed.  Needs: bash, curl, python3, Rscript.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kernel="$here/../kernel.R"
[ -f "$kernel" ] || { echo "kernel.R not found at $kernel" >&2; exit 1; }

tmp="$(mktemp -d)"
doc="$tmp/doc"
data="$tmp/data"
mkdir -p "$doc" "$data"
printf 'a,b\n1,2\n' > "$doc/df2.csv"

port=$((20000 + RANDOM % 20000))
token="tok-$RANDOM-$$"
proof="proof-$RANDOM-$$"
base="http://127.0.0.1:$port"
json='Content-Type: application/json'
# the kernel takes its secrets from the environment only
export TERN_RMD_TOKEN="$token" TERN_RMD_PROOF="$proof"

pass=0
fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3] got [$2]"; fi; }

# --- helpers -----------------------------------------------------------------

kpid=""
cpid=""
cleanup() {
  if [ -n "$kpid" ] && kill -0 "$kpid" 2>/dev/null; then kill "$kpid" 2>/dev/null; fi
  if [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null; then kill "$cpid" 2>/dev/null; fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# call METHOD PATH [JSON-BODY] [TOKEN] -> writes body to $tmp/body and headers
# to $tmp/hdr, echoes status.  Bodies go as JSON: R's HTTP server swallows
# curl's default form encoding.
call() {
  local m="$1" p="$2" d="${3-}" h="${4-$token}" out
  if [ -n "$d" ]; then
    out=$(curl -s -m 30 -D "$tmp/hdr" -o "$tmp/body" -w '%{http_code}' -H "X-Token: $h" -H "$json" --data-binary "$d" "$base$p")
  else
    out=$(curl -s -m 30 -D "$tmp/hdr" -o "$tmp/body" -w '%{http_code}' -H "X-Token: $h" "$base$p")
  fi
  printf '%s' "$out"
}

# header NAME -> the value of response header NAME in $tmp/hdr ("" if absent)
header() {
  awk -v n="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" 'BEGIN{FS=": "} {gsub("\r",""); if (tolower($1) == n) print $2}' "$tmp/hdr"
}

# py PATH -> prints the value at a dotted path of $tmp/body (JSON)
py() {
  python3 - "$tmp/body" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    if part == "":
        continue
    d = d[int(part)] if part.lstrip("-").isdigit() else d[part]
print(d if isinstance(d, str) else json.dumps(d))
PY
}

# types -> comma separated output item types of $tmp/body
types() {
  python3 - "$tmp/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(",".join(o["type"] for o in d.get("outputs", [])))
PY
}

# pytext -> the first output item's text without R's leading space / newline
pytext() {
  python3 - "$tmp/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d["outputs"][0]["text"].strip())
PY
}

# exec CODE [OPTS] [STREAM] -> status; body lands in $tmp/body
exec_code() {
  python3 - "$1" "${2-}" "${3-}" > "$tmp/req.json" <<'PY'
import json, sys
req = {"id": "t", "code": sys.argv[1]}
if sys.argv[2]:
    req["opts"] = sys.argv[2]
if sys.argv[3]:
    req["stream"] = sys.argv[3]
json.dump(req, sys.stdout)
PY
  call POST /exec "$(cat "$tmp/req.json")"
}

# --- start the kernel --------------------------------------------------------

Rscript "$kernel" --port "$port" --dir "$doc" --data "$data" --idle 120 \
  > "$tmp/kernel.log" 2>&1 &
kpid=$!

ready=no
for _ in $(seq 100); do
  if curl -s -m 1 -H "X-Token: $token" "$base/ping" > /dev/null 2>&1; then ready=yes; break; fi
  kill -0 "$kpid" 2>/dev/null || break
  sleep 0.1
done
if [ "$ready" != yes ]; then
  echo "kernel did not come up; log:" >&2
  cat "$tmp/kernel.log" >&2
  exit 1
fi

# --- ping / auth / routing ---------------------------------------------------

st=$(call GET /ping)
same "GET /ping -> 200" "$st" "200"
same "ping ok" "$(py ok)" "true"
same "ping pid is the R process" "$(py pid)" "$kpid"
same "ping version" "$(py version)" "$(Rscript -e 'cat(as.character(getRversion()))')"
same "an authenticated reply proves the session (X-Proof)" "$(header x-proof)" "$proof"

st=$(call GET /ping "" "wrong-token")
same "wrong token -> 403" "$st" "403"
same "wrong token error text" "$(py error)" "bad token"
same "a rejected request never sees the proof" "$(header x-proof)" ""

st=$(curl -s -m 10 -o "$tmp/body" -w '%{http_code}' "$base/ping")
same "missing token -> 403" "$st" "403"

st=$(call GET /nope)
same "unknown path -> 404" "$st" "404"
same "unknown path error" "$(py error)" "not found"

# R's own help server would serve docs and session files; the kernel's
# router replaces it, so those paths need the token and then do not exist
st=$(curl -s -m 10 -o "$tmp/body" -w '%{http_code}' "$base/doc/html/index.html")
same "R help pages need the token" "$st" "403"
st=$(call GET /doc/html/index.html)
same "R help pages are not served" "$st" "404"
st=$(call GET /session/x)
same "R session files are not served" "$st" "404"

st=$(curl -s -m 10 -o "$tmp/body" -w '%{http_code}' -H "X-Token: $token" --data-binary '{"id":"f","code":"1"}' "$base/exec")
same "a form-encoded body -> 400" "$st" "400"
same "the 400 says to send JSON" "$(python3 -c 'import json,sys; print(int("application/json" in json.load(open(sys.argv[1]))["error"]))' "$tmp/body")" "1"

# the server listens on 127.0.0.1 only: through any other address of this
# machine the port must be closed
exposed=$(python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
addrs = set()
try:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.connect(("192.0.2.1", 9))      # no packet is sent; picks the outward address
    addrs.add(probe.getsockname()[0])
    probe.close()
except OSError:
    pass
try:
    addrs.update(socket.gethostbyname_ex(socket.gethostname())[2])
except OSError:
    pass
addrs = [a for a in addrs if not a.startswith("127.")]
if not addrs:
    print("skip")
    sys.exit()
for a in addrs:
    s = socket.socket()
    s.settimeout(2)
    try:
        s.connect((a, port))
        print("open on " + a)
        sys.exit()
    except OSError:
        pass
    finally:
        s.close()
print("closed")
PY
)
if [ "$exposed" = skip ]; then ok "loopback only (no other address to probe)"; else same "the port is closed on every non-loopback address" "$exposed" "closed"; fi

same "the data dir is private (0700)" "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$data")" "0o700"

# the kernel must define nothing in globalenv(), even before the first chunk
st=$(call GET /vars)
same "fresh session: /vars is empty" "$st" "200"
same "fresh session: /vars has no kernel objects" "$(py vars)" "[]"

# --- exec: text, message, warning --------------------------------------------

st=$(exec_code 'x <- 1:10; x * 2')
same "text exec -> 200" "$st" "200"
same "text exec types" "$(types)" "text"
same "text exec content (R pads R's first output line with a space)" "$(py outputs.0.text)" " [1]  2  4  6  8 10 12 14 16 18 20"
same "text exec error flag" "$(py error)" "false"
same "text exec skipped flag" "$(py skipped)" "false"
same "text exec interrupted flag" "$(py interrupted)" "false"

st=$(exec_code 'message("hi"); warning("w")')
same "message/warning types" "$(types)" "message,warning"
same "message keeps trailing newline" "$(py outputs.0.text)" "hi"
same "warning text" "$(py outputs.1.text)" "w"
same "warning call is a string" "$(py outputs.1.call)" ""

# --- exec: errors ------------------------------------------------------------

st=$(exec_code $'stop("boom"); cat("AFTER\\n")')
same "error stops later expressions" "$(types)" "error"
same "error flag" "$(py error)" "true"
same "error message" "$(py outputs.0.text)" "boom"

st=$(exec_code $'stop("boom")\ncat("AFTER\\n")' "error=TRUE")
same "error=TRUE keeps going (types)" "$(types)" "error,text"
same "error=TRUE keeps going (text)" "$(py outputs.1.text)" "AFTER"

st=$(exec_code $'stop("boom")\ncat("AFTER\\n")' "setup, error=TRUE, warning=FALSE")
same "bare label + opts parse" "$(types)" "error,text"

# --- exec: plots -------------------------------------------------------------

st=$(exec_code 'plot(1:10); abline(0,1)')
same "plot types" "$(types)" "plot"
same "one plot per chunk" "$(py outputs.0.file)" "$data/t-1.png"
[ -f "$data/t-1.png" ] && ok "plot png exists" || bad "plot png exists"
dims=$(Rscript -e 'r <- readBin(commandArgs(TRUE)[1], "raw", 33); cat(sum(as.integer(r[17:20]) * 256^(3:0)), "x", sum(as.integer(r[21:24]) * 256^(3:0)), sep = "")' "$data/t-1.png" 2>/dev/null)
same "plot png is 7x5in at 192dpi" "$dims" "1344x960"
same "plot css width (7in * 96)" "$(py outputs.0.width)" "672"
same "plot css height (5in * 96)" "$(py outputs.0.height)" "480"
Rscript -e 'png(commandArgs(TRUE)[1], width = 7 * 192, height = 5 * 192, res = 192, type = "cairo", bg = "white"); plot(1:10); abline(0,1); dev.off()' "$tmp/direct.png" > /dev/null 2>&1
cmp -s "$data/t-1.png" "$tmp/direct.png" && ok "plot png is byte-identical to a direct render" || bad "plot png is byte-identical to a direct render"

st=$(exec_code 'plot(1:5); plot(1:6)' "fig.dim=c(4,3)")
same "two plots -> two items" "$(types)" "plot,plot"
dims=$(Rscript -e 'r <- readBin(commandArgs(TRUE)[1], "raw", 33); cat(sum(as.integer(r[17:20]) * 256^(3:0)), "x", sum(as.integer(r[21:24]) * 256^(3:0)), sep = "")' "$data/t-2.png" 2>/dev/null)
same "fig.dim honoured" "$dims" "768x576"

st=$(exec_code 'plot.new()')
same "blank plot is skipped" "$(types)" ""

# --- exec: tables ------------------------------------------------------------

st=$(exec_code 'head(mtcars)')
same "data.frame -> table item" "$(types)" "table"
same "table class" "$(py outputs.0.class)" "data.frame"
same "table dims" "$(py outputs.0.nrow)x$(py outputs.0.ncol)" "6x11"
same "table cols" "$(py outputs.0.cols.0)" "mpg"
same "table types" "$(py outputs.0.types.0)" "dbl"
same "table rownames" "$(py outputs.0.rownames.0)" "Mazda RX4"
same "table first row" "$(py outputs.0.rows.0)" '["21.0", "6", "160", "110", "3.90", "2.620", "16.46", "0", "1", "4", "4"]'

st=$(exec_code 'data.frame(a=1)')
same "1-row table" "$(py outputs.0.nrow)" "1"
same "default rownames are null" "$(py outputs.0.rownames)" "null"
same "1-row rows stay nested" "$(py outputs.0.rows)" '[["1"]]'

st=$(exec_code 'matrix(1:6, nrow=2)')
same "matrix -> table" "$(py outputs.0.class)" "matrix"
same "matrix cells" "$(py outputs.0.rows)" '[["1", "3", "5"], ["2", "4", "6"]]'

# --- exec: chunk options -----------------------------------------------------

st=$(exec_code 'cat("SHOULD-NOT-RUN\n")' "eval=FALSE")
same "eval=FALSE -> skipped" "$(py skipped)" "true"
same "eval=FALSE -> no outputs" "$(types)" ""

st=$(exec_code 'cat("hidden\n"); message("m")' "results='hide', message=FALSE")
same "results=hide drops text, message=FALSE drops messages" "$(types)" ""

# --- exec: streaming ---------------------------------------------------------

stream="$data/stream.jsonl"
st=$(exec_code 'cat("one\n"); message("two")' "" "$stream")
same "stream exec ok" "$(py ok)" "true"
lines=$(wc -l < "$stream" 2>/dev/null || echo 0)
[ "${lines:-0}" -ge 2 ] && ok "stream file has one line per item ($lines)" || bad "stream file has one line per item (got ${lines:-0})"
streamok=$(python3 - "$stream" <<'PY'
import json, sys
kinds = [json.loads(l)["type"] for l in open(sys.argv[1], encoding="utf-8")]
print("yes" if kinds == ["text", "message"] else "no: %r" % kinds)
PY
)
same "stream lines are items" "$streamok" "yes"

# --- exec: utf-8 + content-length -------------------------------------------

curl -s -m 30 -D "$tmp/hdr" -o "$tmp/body" -H "X-Token: $token" -H "$json" \
  --data-binary '{"id":"utf","code":"cat(\"h\u00e9llo \u2713\\n\")"}' "$base/exec"
utf8=$(python3 - "$tmp/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("yes" if d["outputs"][0]["text"] == "h\u00e9llo \u2713\n" else "no")
PY
)
same "utf-8 round trip" "$utf8" "yes"
same "content-type" "$(awk 'BEGIN{IGNORECASE=1} /^content-type:/ {gsub("\r",""); print $2}' "$tmp/hdr")" "application/json;"
same "connection: close" "$(awk 'BEGIN{IGNORECASE=1} /^connection:/ {gsub("\r",""); print $2}' "$tmp/hdr")" "close"
same "content-length in bytes" "$(awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub("\r",""); print $2}' "$tmp/hdr")" "$(wc -c < "$tmp/body" | tr -d ' ')"
same "utf8 png file follow-up still works" "$(call POST /exec '{"id":"u2","code":"1+1"}' | head -c 3)" "200"

# --- complete / vars ---------------------------------------------------------

st=$(exec_code 'model1 <- 1; mode <- "x"; df2 <- read.csv("df2.csv")')
same "session setup exec" "$(py ok)" "true"

st=$(call POST /complete '{"line":"summary(mod"}')
same "complete status" "$st" "200"
same "complete token" "$(py token)" "mod"
same "complete matches model1" "$(python3 -c 'import json,sys; print("yes" if "model1" in json.load(open(sys.argv[1]))["matches"] else "no")' "$tmp/body")" "yes"

st=$(call POST /complete '{"line":"summ"}')
same "complete token for summ" "$(py token)" "summ"
same "complete matches summary" "$(python3 -c 'import json,sys; print("yes" if "summary" in json.load(open(sys.argv[1]))["matches"] else "no")' "$tmp/body")" "yes"

st=$(call GET /vars)
same "vars status" "$st" "200"
same "vars has df2" "$(python3 -c 'import json,sys; print("yes" if any(v["name"]=="df2" and v["class"]=="data.frame" for v in json.load(open(sys.argv[1]))["vars"]) else "no")' "$tmp/body")" "yes"
same "vars summary non-empty" "$(python3 -c 'import json,sys; v=[x for x in json.load(open(sys.argv[1]))["vars"] if x["name"]=="df2"][0]; print("yes" if isinstance(v["summary"],str) and v["summary"] else "no")' "$tmp/body")" "yes"

# --- interrupt ---------------------------------------------------------------

( call POST /exec '{"id":"e-int","code":"Sys.sleep(30)"}' > "$tmp/status_int" ) &
curljob=$!
sleep 0.5
t0=$(date +%s%N)
kill -INT "$kpid"
wait "$curljob"
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
same "interrupted exec -> 200" "$(cat "$tmp/status_int")" "200"
same "interrupted flag" "$(py interrupted)" "true"
same "interrupted error flag" "$(py error)" "true"
same "interrupted item" "$(py outputs.0.type)" "error"
same "interrupted text" "$(py outputs.0.text)" "Interrupted"
[ "$ms" -lt 3000 ] && ok "interrupt answered in ${ms}ms" || bad "interrupt answered in ${ms}ms (expected < 3000)"
same "interrupted exec did not ping-wait the idle clock (200 + body)" "$(types)" "error"

st=$(exec_code $'x[1]\ncat("alive\\n")')
same "session survives interrupt (consecutive text merged)" "$(types)" "text"
same "session state kept" "$(python3 - "$tmp/body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("yes" if d["outputs"][0]["text"] == "[1] 1\nalive\n" else repr(d["outputs"][0]["text"]))
PY
)" "yes"

st=$(call GET /ping)
same "kernel still serves after interrupt" "$(py ok)" "true"

# --- extras ------------------------------------------------------------------

st=$(exec_code 'View(mtcars)')
same "View() -> table" "$(types)" "table"
same "View() table dims" "$(py outputs.0.nrow)x$(py outputs.0.ncol)" "32x11"

st=$(exec_code $'cat("x\\n"); View(mtcars); cat("y\\n")')
same "View() keeps output order" "$(types)" "text,table,text"

st=$(call POST /exec '{"id":"mr","code":"mtcars","max_rows":3}')
same "max_rows truncates rows" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["outputs"][0]; print("%d/%d" % (len(d["rows"]), d["nrow"]))' "$tmp/body")" "3/32"

st=$(exec_code 'x +')
same "syntax error -> error output" "$(types)" "error"
same "syntax error flagged" "$(py error)" "true"

st=$(exec_code '1:40')
same "width option is honoured (default 80 -> 2 wrapped lines)" "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["outputs"][0]["text"]; print(len([l for l in t.splitlines() if l.strip()]))' "$tmp/body")" "2"
st=$(call POST /exec '{"id":"w","code":"1:40","width":30}')
same "width option narrows wrapping" "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["outputs"][0]["text"]; print(len([l for l in t.splitlines() if l.strip()]))' "$tmp/body")" "5"

# --- secrets and output limits -------------------------------------------------

st=$(exec_code 'cat(Sys.getenv("TERN_RMD_TOKEN"), Sys.getenv("TERN_RMD_PROOF"), "|", sep = "")')
same "chunks cannot read the session's secrets" "$(pytext)" "|"
st=$(exec_code 'system("env | grep -c TERN_RMD_TOKEN || true", intern = TRUE)')
same "subprocesses do not inherit the secrets" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outputs"][0]["text"].split()[-1])' "$tmp/body")" '"0"'

st=$(exec_code '1' 'x), cat("SMUGGLED\n"), alist(y')
same "a ) in the chunk header cannot run extra code" "$(pytext)" "[1] 1"

st=$(exec_code 'cat(strrep("x", 5e6))')
same "a huge print is clipped" "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["outputs"][0]["text"]; print(int(len(t) < 210000) + int("characters omitted" in t))' "$tmp/body")" "2"

st=$(exec_code 'for (i in 1:5000) message(i)')
same "a flood of messages is capped" "$(python3 -c 'import json,sys; o=json.load(open(sys.argv[1]))["outputs"]; print(len(o), int("more outputs not shown" in o[-1]["text"]))' "$tmp/body")" "2001 1"

st=$(exec_code $'for (i in 1:3000) message(i)\nstop("late")')
same "an error past the cap still fails the chunk" "$(py error)" "true"

st=$(exec_code 'm <- matrix(1:2, 1); colnames(m) <- c("a", NA); m')
same "NA column names arrive as \"NA\"" "$(py outputs.0.cols)" '["a", "NA"]'

# --- globalenv hygiene: the kernel must not depend on (or leak into) it ------

st=$(exec_code $'rm(list = ls())\ny <- 41\ny')
same "rm(list = ls()) does not delete the kernel" "$(pytext)" "[1] 41"
st=$(exec_code 'y + 1')
same "next chunk answers after rm(list = ls())" "$(pytext)" "[1] 42"
rm -f "$data/t-1.png"
st=$(exec_code 'plot(1:5)')
same "plot after rm(list = ls()) still renders" "$(types)" "plot"
[ -f "$data/t-1.png" ] && ok "plot png written after rm(list = ls())" || bad "plot png written after rm(list = ls())"
st=$(call GET /vars)
same "/vars shows only the user's objects" "$(python3 -c 'import json,sys; print(",".join(sorted(v["name"] for v in json.load(open(sys.argv[1]))["vars"])))' "$tmp/body")" "y"
st=$(call POST /complete '{"line":"y +"}')
same "/complete still answers" "$(py ok)" "true"

st=$(exec_code $'json_str <- function(...) "boom"\nrespond_json <- 1\nroute_request <- 1\ncat("shadowed\\n")')
same "user code can reuse kernel names" "$(pytext)" "shadowed"
st=$(call GET /vars)
same "kernel keeps answering after shadowing attempts" "$(py ok)" "true"

# --- device safety -----------------------------------------------------------

[ ! -e "$doc/Rplots.pdf" ] && ok "no Rplots.pdf in the document dir" || bad "no Rplots.pdf in the document dir"

# --- idle timeout ------------------------------------------------------------

iport=$((port + 1))
Rscript "$kernel" --port "$iport" --dir "$doc" --data "$data" --idle 3 \
  > "$tmp/kernel_idle.log" 2>&1 &
ipid=$!
for _ in $(seq 100); do
  curl -s -m 1 -H "X-Token: $token" "http://127.0.0.1:$iport/ping" > /dev/null 2>&1 && break
  sleep 0.1
done
# pings reset the idle clock, so the kernel must survive well past 3 seconds
alive=yes
for _ in 1 2 3 4 5; do
  kill -0 "$ipid" 2>/dev/null || { alive=no; break; }
  curl -s -m 1 -H "X-Token: $token" "http://127.0.0.1:$iport/ping" > /dev/null
  sleep 1
done
same "pings keep the idle kernel alive past --idle" "$alive" "yes"
t0=$(date +%s)
wait "$ipid"
ist=$?
elapsed=$(( $(date +%s) - t0 ))
same "idle timeout exits cleanly" "$ist" "0"
[ "$elapsed" -ge 2 ] && [ "$elapsed" -le 12 ] && ok "idle exit within the idle window after the last ping (${elapsed}s)" || bad "idle exit within the idle window after the last ping (${elapsed}s)"

# --- console capture (fd 1/2 of R and of every subprocess) --------------------

cport=$((port + 2))
clog="$data/console.log"
cbase="http://127.0.0.1:$cport"

# the plugin's launch form: fd 1/2 appended into TERN_RMD_LOG, secrets via env
TERN_RMD_LOG="$clog" sh -c 'exec "$@" >>"$TERN_RMD_LOG" 2>&1' sh \
  Rscript "$kernel" --port "$cport" --dir "$doc" --data "$data" --idle 120 &
cpid=$!
cready=no
for _ in $(seq 100); do
  curl -s -m 1 -H "X-Token: $token" "$cbase/ping" > /dev/null 2>&1 && { cready=yes; break; }
  kill -0 "$cpid" 2>/dev/null || break
  sleep 0.1
done
same "kernel starts with TERN_RMD_LOG + TERN_RMD_TOKEN" "$cready" "yes"

# cexec CODE -> status; body lands in $tmp/body
cexec() {
  python3 - "$1" > "$tmp/req.json" <<'PY'
import json, sys
json.dump({"id": "cc", "code": sys.argv[1]}, sys.stdout)
PY
  curl -s -m 30 -o "$tmp/body" -w '%{http_code}' -H "X-Token: $token" -H "$json" \
    --data-binary "$(cat "$tmp/req.json")" "$cbase/exec"
}

st=$(cexec 'system("echo hi-from-shell")')
same "shell output -> console item" "$(types)" "console"
same "shell output text" "$(py outputs.0.text)" "hi-from-shell"
same "console item carries upto" "$(python3 -c 'import json,sys; print(int(float(json.load(open(sys.argv[1]))["outputs"][0]["upto"]) > 0))' "$tmp/body")" "1"

st=$(cexec $'cat("a\\n"); system("echo b"); cat("c\\n")')
same "console interleaves in order (types)" "$(types)" "text,console,text"
same "order: text a" "$(py outputs.0.text)" "a"
same "order: console b" "$(py outputs.1.text)" "b"
same "order: text c" "$(py outputs.2.text)" "c"

st=$(cexec '1 + 1')
same "exec after console output is text only" "$(types)" "text"
same "previous console output is not repeated" "$(pytext)" "[1] 2"
same "console log was reset for that exec" "$(python3 -c 'import sys; print(int(__import__("os").path.getsize(sys.argv[1]) == 0))' "$clog")" "1"

st=$(cexec $'cat("to-stderr\\n", file = stderr()); flush(stderr())')
same "stderr output -> console item" "$(types)" "console"
same "stderr text" "$(py outputs.0.text)" "to-stderr"

st=$(cexec 'system("head -c 200000 /dev/zero | tr \"\\0\" x")')
same "huge console output -> one console item" "$(types)" "console"
same "huge item is truncated with a file reference" "$(python3 -c 'import json,sys; o=json.load(open(sys.argv[1]))["outputs"][0]; print(int("bytes omitted" in o["text"]) + int("file" in o))' "$tmp/body")" "2"
same "truncated item keeps first 8 KiB and last 48 KiB" "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1]))["outputs"][0]["text"]; print(int(t.startswith("x"*8192)) + int(t.endswith("x"*49152)))' "$tmp/body")" "2"
same "truncated item file exists and holds the whole log" "$(python3 -c 'import json,sys,os; o=json.load(open(sys.argv[1]))["outputs"][0]; print(int(os.path.exists(o["file"]) and os.path.getsize(o["file"]) >= 200000))' "$tmp/body")" "1"
same "console log file is in the data dir" "$(python3 -c 'import json,sys,os; o=json.load(open(sys.argv[1]))["outputs"][0]; print(os.path.dirname(o["file"]))' "$tmp/body")" "$data"

st=$(cexec 'system("printf \"\\377\\376 bad bytes\\n\"")')
same "invalid utf-8 does not break the reply" "$(python3 -c 'import json,sys; print(int(json.load(open(sys.argv[1], encoding="utf-8")).get("ok") is True))' "$tmp/body")" "1"
same "invalid utf-8 is sanitised" "$(python3 -c 'import json,sys; t=json.load(open(sys.argv[1], encoding="utf-8"))["outputs"][0]["text"]; print(int("bad bytes" in t and "?" in t))' "$tmp/body")" "1"

cstream="$data/console-stream.jsonl"
python3 -c 'import json,sys; json.dump({"id":"cc-stream","code":"system(\"echo streamed\")","stream":sys.argv[1]}, sys.stdout)' "$cstream" > "$tmp/req.json"
st=$(curl -s -m 30 -o "$tmp/body" -w '%{http_code}' -H "X-Token: $token" -H "$json" --data-binary @"$tmp/req.json" "$cbase/exec")
same "console items are streamed like every other item" "$(python3 -c 'import json,sys; print(",".join(json.loads(l)["type"] for l in open(sys.argv[1], encoding="utf-8")))' "$cstream")" "console"

st=$(python3 -c 'import json,sys; json.dump({"id":"cc-log","code":"1+1","stream":"/nonexistent-dir/x.jsonl"}, sys.stdout)' > "$tmp/req.json"
   curl -s -m 30 -o "$tmp/body" -w '%{http_code}' -H "X-Token: $token" -H "$json" --data-binary "$(cat "$tmp/req.json")" "$cbase/exec")
same "kernel log_msg does not leak into console items" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(int(any("cannot open stream file" in o.get("text","") for o in d["outputs"])))' "$tmp/body")" "0"
same "kernel diagnostics land in DATADIR/kernel.log" "$(grep -c "cannot open stream file" "$data/kernel.log" 2>/dev/null || true)" "1"
same "console log stays free of kernel diagnostics" "$(grep -c "cannot open stream file" "$clog" 2>/dev/null || true)" "0"

# --log PATH works as an alternative to the environment variable
lport=$((port + 3))
log2="$data/console2.log"
sh -c 'log="$1"; shift; exec "$@" >>"$log" 2>&1' sh "$log2" Rscript "$kernel" \
  --port "$lport" --dir "$doc" --data "$data" --log "$log2" --idle 120 &
lpid=$!
lready=no
for _ in $(seq 100); do
  curl -s -m 1 -H "X-Token: $token" "http://127.0.0.1:$lport/ping" > /dev/null 2>&1 && { lready=yes; break; }
  kill -0 "$lpid" 2>/dev/null || break
  sleep 0.1
done
same "--log kernel starts" "$lready" "yes"
python3 -c 'import json,sys; json.dump({"id":"cl","code":"system(\"echo via-log-flag\")"}, sys.stdout)' > "$tmp/req.json"
curl -s -m 30 -o "$tmp/body" -H "X-Token: $token" -H "$json" --data-binary "$(cat "$tmp/req.json")" "http://127.0.0.1:$lport/exec" > /dev/null
same "--log captures shell output" "$(types)" "console"
same "--log shell text" "$(py outputs.0.text)" "via-log-flag"
curl -s -m 5 -H "X-Token: $token" -H "$json" --data-binary '{}' "http://127.0.0.1:$lport/shutdown" > /dev/null
wait "$lpid" 2>/dev/null

curl -s -m 5 -H "X-Token: $token" -H "$json" --data-binary '{}' "$cbase/shutdown" > /dev/null
wait "$cpid" 2>/dev/null
cpid=""

# --- shutdown ----------------------------------------------------------------

st=$(call POST /shutdown '{}')
same "shutdown -> 200" "$st" "200"
same "shutdown ok" "$(py ok)" "true"
wait "$kpid"
same "kernel exits 0 on shutdown" "$?" "0"
kpid=""

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
