#!/usr/bin/env python3
"""
run_all.py — fast, rate-limited batch cold-email personalizer.

Reads a leads CSV, then fetches each article and calls the model CONCURRENTLY
(a thread pool) while globally capping model requests to NVIDIA's rate limit
(default 38/min, just under the 40 limit for headroom). Writes ONE enriched CSV:
every original column PLUS first_name and topic.

Why this is fast: the old bash loop was sequential (~10 leads/min). Here, many
articles are fetched in parallel and the only thing rate-limited is the model
call, so throughput rises to ~the RPM cap. 249 leads ≈ 7 minutes instead of ~25.

Resumable: skips any lead whose email is already in the output CSV, so you can
re-run to pick up failures (Ctrl-C safe — rows are flushed as they finish).

Usage:
  python3 run_all.py "USA TODAY - EMAILS - JUN 12 - Safe emails.csv"

Env (all optional; NVIDIA_* are loaded from .env automatically):
  OUT          output CSV (default: <input> with "_personalized" before .csv)
  RPM          max model requests per minute (default 38)
  CONCURRENCY  worker threads (default 8)
  LIMIT        process only the first N leads (0 = all; for testing)
  REVIEW_LOG   default review.log   (INSUFFICIENT / FETCH_FAILED / no url)
  FAILED_LOG   default failed.log   (model/JSON errors)
  Plus every personalize_llm.py var (NVIDIA_MODEL, LLM_REASONING_EFFORT, ...).
"""

import csv
import json
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable


# --- load .env (so NVIDIA_API_KEY etc. are available to child processes) ------
def load_dotenv(path):
    if not os.path.isfile(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


# --- global rate limiter: spaces out model calls to <= RPM per minute ---------
class RateLimiter:
    def __init__(self, rpm):
        self.interval = 60.0 / max(rpm, 1)
        self.lock = threading.Lock()
        self.next_t = 0.0

    def wait(self):
        with self.lock:
            now = time.monotonic()
            if now < self.next_t:
                time.sleep(self.next_t - now)
                now = time.monotonic()
            self.next_t = now + self.interval


# --- pull the first balanced {...} object out of arbitrary model output -------
def extract_json(text):
    depth = 0
    start = None
    instr = False
    esc = False
    for i, c in enumerate(text):
        if esc:
            esc = False
            continue
        if c == "\\":
            esc = True
            continue
        if c == '"':
            instr = not instr
            continue
        if instr:
            continue
        if c == "{":
            if depth == 0:
                start = i
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0 and start is not None:
                return text[start : i + 1]
    return ""


def pick_col(fieldnames, candidates):
    lower = {f.lower(): f for f in fieldnames}
    for c in candidates:
        if c.lower() in lower:
            return lower[c.lower()]
    return None


def process_lead(row, cols, limiter, timeout):
    """Returns (status, email, note, enriched_row). status in ok/review/failed."""
    full_name = (row.get(cols["name"]) or "").strip()
    article_url = (row.get(cols["article"]) or "").strip()
    linkedin = (row.get(cols["linkedin"]) or "").strip() if cols["linkedin"] else ""
    email = (row.get(cols["email"]) or "").strip() if cols["email"] else ""

    out = dict(row)
    out["first_name"] = ""
    out["topic"] = ""

    if not article_url:
        return ("review", email, "no_article_url", out)

    # 1) fetch the article (not rate-limited — it's not an NVIDIA request)
    try:
        fetch = subprocess.run(
            [PY, os.path.join(SCRIPT_DIR, "fetch_article.py"), article_url],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return ("review", email, "FETCH_FAILED(timeout)", out)
    if fetch.returncode != 0 or len(fetch.stdout.strip()) < 1:
        return ("review", email, f"FETCH_FAILED(exit={fetch.returncode})", out)
    article_content = fetch.stdout

    # 2) model call — gated by the global rate limiter
    limiter.wait()
    try:
        model = subprocess.run(
            [PY, os.path.join(SCRIPT_DIR, "personalize_llm.py"),
             "--full_name", full_name, "--article_url", article_url,
             "--linkedin", linkedin, "--email", email],
            input=article_content, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return ("failed", email, "llm_timeout", out)
    if model.returncode != 0:
        return ("failed", email, f"llm_exit={model.returncode}: {model.stderr.strip()[:160]}", out)

    js = extract_json(model.stdout)
    if not js:
        return ("failed", email, "no_json_in_output", out)
    try:
        data = json.loads(js)
    except json.JSONDecodeError as exc:
        return ("failed", email, f"bad_json: {exc}", out)

    topic = (data.get("topic") or "").strip()
    out["first_name"] = (data.get("first_name") or "").strip()
    out["topic"] = topic
    if topic in ("", "INSUFFICIENT", "FETCH_FAILED"):
        out["topic"] = topic or "INSUFFICIENT"
        return ("review", email, out["topic"], out)
    return ("ok", email, "", out)


def main():
    load_dotenv(os.path.join(SCRIPT_DIR, ".env"))
    os.environ.setdefault("LLM_TIMEOUT", "120")  # keep a stuck call from holding a worker forever

    if len(sys.argv) != 2:
        sys.stderr.write('usage: run_all.py "<leads.csv>"\n')
        return 64
    in_path = sys.argv[1]
    if not os.path.isfile(in_path):
        sys.stderr.write(f"input file not found: {in_path}\n")
        return 1

    rpm = float(os.environ.get("RPM", "38"))
    concurrency = int(os.environ.get("CONCURRENCY", "8"))
    limit = int(os.environ.get("LIMIT", "0"))
    review_log = os.environ.get("REVIEW_LOG", "review.log")
    failed_log = os.environ.get("FAILED_LOG", "failed.log")
    base, ext = os.path.splitext(in_path)
    out_path = os.environ.get("OUT", f"{base}_personalized{ext or '.csv'}")
    timeout = float(os.environ.get("LLM_TIMEOUT", "120")) + 30

    # --- read input (utf-8-sig strips any BOM from a Google Sheets export) ----
    with open(in_path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        in_fields = reader.fieldnames or []
        rows = list(reader)

    cols = {
        "name": pick_col(in_fields, ["full_name", "Name", "name", "Full Name"]),
        "article": pick_col(in_fields, ["article_url", "article", "Article", "url", "URL"]),
        "linkedin": pick_col(in_fields, ["linkedin", "LinkedIn", "linkedin_url", "LinkedIn URL"]),
        "email": pick_col(in_fields, ["email", "Email", "email_address", "Email Address"]),
    }
    if not cols["name"] or not cols["article"]:
        sys.stderr.write(f"could not find name/article columns in header: {in_fields}\n")
        return 1

    out_fields = list(in_fields) + [c for c in ("first_name", "topic") if c not in in_fields]

    # --- resume: skip emails already written to OUT ---------------------------
    done = set()
    out_exists = os.path.isfile(out_path)
    if out_exists and cols["email"]:
        with open(out_path, newline="", encoding="utf-8-sig") as fh:
            for r in csv.DictReader(fh):
                e = (r.get(cols["email"]) or "").strip()
                if e:
                    done.add(e)

    todo = []
    for r in rows:
        if limit and len(todo) >= limit:
            break
        e = (r.get(cols["email"]) or "").strip() if cols["email"] else ""
        if e and e in done:
            continue
        todo.append(r)

    total = len(todo)
    print(f"Input: {in_path}  ({len(rows)} rows, {len(done)} already done)")
    print(f"Output: {out_path}")
    print(f"Model: {os.environ.get('NVIDIA_MODEL', '<default>')}  |  RPM cap: {rpm:g}  |  workers: {concurrency}")
    print(f"Processing {total} leads...")
    print("-" * 60)
    if total == 0:
        print("Nothing to do.")
        return 0

    limiter = RateLimiter(rpm)
    write_lock = threading.Lock()
    out_fh = open(out_path, "a", newline="", encoding="utf-8")
    writer = csv.DictWriter(out_fh, fieldnames=out_fields, extrasaction="ignore")
    if not out_exists:
        writer.writeheader()
        out_fh.flush()

    counts = {"ok": 0, "review": 0, "failed": 0}
    started = time.monotonic()
    n_done = 0

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(process_lead, r, cols, limiter, timeout) for r in todo]
        for fut in as_completed(futures):
            status, email, note, out_row = fut.result()
            with write_lock:
                n_done += 1
                counts[status] += 1
                if status == "ok":
                    writer.writerow(out_row)
                    out_fh.flush()
                    print(f"[{n_done}/{total}] OK    {email}  ->  {out_row['topic']}")
                elif status == "review":
                    writer.writerow(out_row)  # keep the row (topic=INSUFFICIENT) so it isn't retried forever
                    out_fh.flush()
                    with open(review_log, "a", encoding="utf-8") as lf:
                        lf.write(f"{email} | {note}\n")
                    print(f"[{n_done}/{total}] SKIP  {email}  ({note})")
                else:
                    with open(failed_log, "a", encoding="utf-8") as lf:
                        lf.write(f"{email} | {note}\n")
                    print(f"[{n_done}/{total}] FAIL  {email}  ({note})")

    out_fh.close()
    elapsed = time.monotonic() - started
    rate = (n_done / elapsed * 60) if elapsed else 0
    print("-" * 60)
    print(f"Done in {elapsed/60:.1f} min  ({rate:.0f} leads/min).")
    print(f"  ok={counts['ok']}  review={counts['review']}  failed={counts['failed']}")
    print(f"  enriched CSV: {out_path}")
    if counts["failed"]:
        print(f"  re-run the same command to retry the {counts['failed']} failed lead(s) (resume skips finished ones).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
