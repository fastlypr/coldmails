#!/usr/bin/env python3
"""
compare_models.py — run several LLMs on the SAME leads, side by side.

For each lead it fetches the article ONCE, then asks every model in MODELS for a
topic and writes each model's answer into its own column, so you can compare
which LLM writes the best line. Reuses the tested helpers + personalize_llm.py.

Output columns: all original columns + first_name + one `topic__<alias>` per model
(alias = the part after the last "/" in the model id).

Usage:
  MODELS="openai/gpt-oss-120b,nvidia/nemotron-3-ultra-550b-a55b,meta/llama-3.3-70b-instruct" \
    python3 compare_models.py "leads.csv"
  python3 compare_models.py "https://docs.google.com/spreadsheets/d/<ID>/edit"

Env:
  MODELS       comma-separated model ids to compare (default: gpt-oss + nemotron)
  OUT          output CSV (default: <input>_compare.csv, or gsheet_compare.csv)
  RPM          rate cap per minute across ALL model calls (default 40)
  CONCURRENCY  leads processed at once (default 5)
  LIMIT        only the first N leads (great for a quick test)
  (+ every NVIDIA_* / LLM_* var, loaded from .env)
"""

import csv
import io
import json
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

# Reuse the tested helpers from run_all.py (same folder).
from run_all import (
    load_dotenv, RateLimiter, clean_text, extract_json, pick_col,
    is_gsheet, download_gsheet, write_atomic, SCRIPT_DIR, PY,
)

DEFAULT_MODELS = "openai/gpt-oss-120b,nvidia/nemotron-3-ultra-550b-a55b"


def alias(model):
    return model.split("/")[-1].strip()


def one_model(article_content, full_name, article_url, linkedin, email, model, timeout):
    """Call personalize_llm.py with a specific model; return the clean topic."""
    env = os.environ.copy()
    env["NVIDIA_MODEL"] = model
    try:
        r = subprocess.run(
            [PY, os.path.join(SCRIPT_DIR, "personalize_llm.py"),
             "--full_name", full_name, "--article_url", article_url,
             "--linkedin", linkedin, "--email", email],
            input=article_content, capture_output=True, text=True,
            timeout=timeout, env=env,
        )
    except subprocess.TimeoutExpired:
        return "", ""
    if r.returncode != 0:
        return "", ""
    js = extract_json(r.stdout)
    if not js:
        return "", ""
    try:
        data = json.loads(js)
    except json.JSONDecodeError:
        return "", ""
    return clean_text((data.get("first_name") or "").strip()), \
        clean_text((data.get("topic") or "").strip())


def process_lead(idx, full_name, article_url, linkedin, email, models, limiter, timeout):
    aliases = [alias(m) for m in models]
    topics = {a: "" for a in aliases}
    first_name = ""

    if not article_url:
        return (idx, "no_article_url", first_name, topics)

    try:
        fetch = subprocess.run(
            [PY, os.path.join(SCRIPT_DIR, "fetch_article.py"), article_url],
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return (idx, "FETCH_FAILED", first_name, topics)
    if fetch.returncode != 0 or len(fetch.stdout.strip()) < 1:
        return (idx, "FETCH_FAILED", first_name, topics)
    article = fetch.stdout

    # Ask each model (each call is rate-limited against the shared RPM cap).
    for model in models:
        limiter.wait()
        fn, tp = one_model(article, full_name, article_url, linkedin, email, model, timeout)
        topics[alias(model)] = tp
        if fn and not first_name:
            first_name = fn
    return (idx, "ok", first_name, topics)


def main():
    load_dotenv(os.path.join(SCRIPT_DIR, ".env"))
    os.environ.setdefault("LLM_TIMEOUT", "120")

    if len(sys.argv) >= 2:
        in_arg = sys.argv[1]
    elif os.environ.get("IN"):
        in_arg = os.environ["IN"].strip()
    else:
        sys.stderr.write('usage: compare_models.py "<leads.csv | sheet-url>"\n')
        return 64

    models = [m.strip() for m in os.environ.get("MODELS", DEFAULT_MODELS).split(",") if m.strip()]
    aliases = [alias(m) for m in models]
    rpm = float(os.environ.get("RPM", "40"))
    concurrency = int(os.environ.get("CONCURRENCY", "5"))
    limit = int(os.environ.get("LIMIT", "0"))
    timeout = float(os.environ.get("LLM_TIMEOUT", "120")) + 30

    # --- read input ---
    if is_gsheet(in_arg):
        try:
            text = download_gsheet(in_arg)
        except Exception as exc:
            sys.stderr.write(f"sheet download failed: {exc}\n")
            return 1
        reader = csv.DictReader(io.StringIO(text))
        source_fields = list(reader.fieldnames or [])
        rows = list(reader)
        default_out = "gsheet_compare.csv"
    else:
        if not os.path.isfile(in_arg):
            sys.stderr.write(f"input file not found: {in_arg}\n")
            return 1
        with open(in_arg, newline="", encoding="utf-8-sig") as fh:
            reader = csv.DictReader(fh)
            source_fields = list(reader.fieldnames or [])
            rows = list(reader)
        base, ext = os.path.splitext(in_arg)
        default_out = f"{base}_compare{ext or '.csv'}"
    out_path = os.environ.get("OUT", default_out)

    name_col = pick_col(source_fields, ["full_name", "Name", "name", "Full Name"])
    article_col = pick_col(source_fields, ["article_url", "article", "Article", "url", "URL"])
    linkedin_col = pick_col(source_fields, ["linkedin", "LinkedIn", "linkedin_url"])
    email_col = pick_col(source_fields, ["email", "Email", "email_address", "Email Address"])
    if not name_col or not article_col:
        sys.stderr.write(f"could not find name/article columns in: {source_fields}\n")
        return 1

    fn_col = pick_col(source_fields, ["first_name", "First Name"]) or "first_name"
    topic_cols = [f"topic__{a}" for a in aliases]
    out_fields = list(source_fields)
    for c in [fn_col] + topic_cols:
        if c not in out_fields:
            out_fields.append(c)

    # --- resume: skip a lead only if ALL model columns are already filled ---
    todo = []
    already = 0
    for idx, row in enumerate(rows):
        for c in [fn_col] + topic_cols:
            row.setdefault(c, row.get(c, ""))
        if all((row.get(c) or "").strip() for c in topic_cols):
            already += 1
            continue
        if limit and len(todo) >= limit:
            continue
        todo.append((idx, (row.get(name_col) or "").strip(),
                     (row.get(article_col) or "").strip(),
                     (row.get(linkedin_col) or "").strip() if linkedin_col else "",
                     (row.get(email_col) or "").strip() if email_col else ""))

    total = len(todo)
    print(f"Input: {in_arg}  ({len(rows)} rows, {already} already done)")
    print(f"Output: {out_path}")
    print(f"Models: {', '.join(models)}")
    print(f"RPM cap: {rpm:g}  |  workers: {concurrency}  |  calls/lead: {len(models)}")
    print(f"Processing {total} leads ({total * len(models)} model calls)...")
    print("-" * 60)
    if total == 0:
        write_atomic(out_path, out_fields, rows)
        print("Nothing to do.")
        return 0

    limiter = RateLimiter(rpm)
    lock = threading.Lock()
    started = time.monotonic()
    n_done = 0

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(process_lead, *t, models, limiter, timeout) for t in todo]
        for fut in as_completed(futures):
            idx, status, first_name, topics = fut.result()
            with lock:
                n_done += 1
                if first_name:
                    rows[idx][fn_col] = first_name
                for a in aliases:
                    rows[idx][f"topic__{a}"] = topics.get(a, "")
                shown = "  |  ".join(f"{a}: {topics.get(a, '') or status}" for a in aliases)
                print(f"[{n_done}/{total}] {rows[idx].get(email_col, '')}")
                print(f"     {shown}")
                if n_done % 10 == 0:
                    write_atomic(out_path, out_fields, rows)

    write_atomic(out_path, out_fields, rows)
    elapsed = time.monotonic() - started
    print("-" * 60)
    print(f"Done in {elapsed/60:.1f} min. Compare the topic__ columns in: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
