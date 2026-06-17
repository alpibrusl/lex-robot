#!/usr/bin/env python3
"""Record the robot bazaar demo as a WebM video via Playwright.

Usage:
    VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \
    VERTEX_PROJECT=elusmart-dev \
    python3 examples/record_demo.py

The script starts all four sidecars, opens a Chromium window that records
video of the dashboard, runs the lex demo, waits for completion, then saves
bazaar_demo.webm in the examples/ directory.
"""

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("playwright not installed — run: pip3 install playwright && python3 -m playwright install chromium")
    sys.exit(1)

REPO = Path(__file__).parent.parent
OUT  = REPO / "examples" / "bazaar_demo.webm"


def wait_healthy(port: int, retries: int = 20) -> bool:
    import urllib.request, urllib.error
    for _ in range(retries):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1)
            return True
        except Exception:
            time.sleep(0.3)
    return False


def main() -> None:
    env = os.environ.copy()
    if not env.get("VERTEX_ACCESS_TOKEN"):
        print("ERROR: VERTEX_ACCESS_TOKEN not set")
        sys.exit(1)
    if not env.get("VERTEX_PROJECT"):
        print("ERROR: VERTEX_PROJECT not set")
        sys.exit(1)
    env.setdefault("VERTEX_LOCATION", "eu")

    # ── Start sidecars ─────────────────────────────────────────────────────────
    sidecar = str(REPO / "sidecar" / "sim_sidecar.py")
    procs   = []
    for port, stall in [(8900, ""), (8901, "pottery"), (8902, "textile"), (8903, "spices")]:
        e = dict(env, LEX_ROBOT_SIDECAR_PORT=str(port))
        if stall:
            e["LEX_STALL_NAME"] = stall
        p = subprocess.Popen(["python3", sidecar], env=e,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs.append(p)

    for port in [8900, 8901, 8902, 8903]:
        if not wait_healthy(port):
            print(f"ERROR: sidecar on :{port} did not start")
            for p in procs:
                p.terminate()
            sys.exit(1)
    print("All sidecars healthy — http://localhost:8900")

    # ── Recording + demo ───────────────────────────────────────────────────────
    video_dir = str(REPO / "examples" / "_video_tmp")
    Path(video_dir).mkdir(exist_ok=True)

    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=False)
            ctx = browser.new_context(
                viewport={"width": 1440, "height": 900},
                record_video_dir=video_dir,
                record_video_size={"width": 1440, "height": 900},
            )
            page = ctx.new_page()
            page.goto("http://localhost:8900")
            print("Dashboard open — starting demo …")
            time.sleep(1)

            # Run the demo (terminal output streams to our stdout)
            demo = subprocess.Popen(
                ["lex", "run",
                 "--allow-effects", "env,fs_write,io,llm,net,proc,sense,sql,time",
                 str(REPO / "examples" / "bazaar_demo.lex"), "run"],
                env=env,
            )

            # Wait for demo to finish (the process exits naturally)
            demo.wait()
            print("Demo finished — waiting for dashboard to settle …")
            time.sleep(10)

            page.close()
            ctx.close()
            browser.close()

        # Rename the generated .webm to our target path
        videos = sorted(Path(video_dir).glob("*.webm"),
                        key=lambda p: p.stat().st_mtime, reverse=True)
        if videos:
            shutil.move(str(videos[0]), str(OUT))
            print(f"\nVideo saved → {OUT}")
        else:
            print("No video file found in", video_dir)

    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
        shutil.rmtree(video_dir, ignore_errors=True)
        print("Sidecars stopped.")


if __name__ == "__main__":
    main()
