#!/usr/bin/env python3
"""Record lex-robot demos as WebM + GIF via Playwright.

Usage:
    VERTEX_ACCESS_TOKEN=$(gcloud auth print-access-token) \\
    VERTEX_PROJECT=elusmart-dev \\
    python3 examples/record_demo.py [bazaar|bazaar_rush|heist|station|trading|triage|all]

Output per demo:
    demos/<name>.webm   — full browser recording of the dashboard
    demos/<name>.gif    — 15 fps GIF (palette-optimised, ~3-8 MB)
"""

import os
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).parent.parent
DEMOS = REPO / "demos"
LEX_EFFECTS = "concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time"
LEX_RUN = ["lex", "run", "--allow-effects", LEX_EFFECTS, "--allow-proc", "sh"]
SIDECAR = str(REPO / "sidecar" / "sim_sidecar.lex")

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    sys.exit("playwright not installed — pip install playwright && python3 -m playwright install chromium")


# ── Demo definitions ──────────────────────────────────────────────────────────

DEMOS_CFG = {
    "bazaar": {
        "html":    "bazaar_web.html",
        "script":  "bazaar_demo.lex",
        "stalls": [(8900, ""), (8901, "pottery"), (8902, "textile"), (8903, "spices")],
        "wait_s":  15,
    },
    "bazaar_rush": {
        "html":    "bazaar_web.html",
        "script":  "bazaar_rush.lex",
        "stalls": [(8900, ""), (8901, "pottery"), (8902, "textile"), (8903, "spices"),
                   (8904, "clay"), (8905, "fabric"), (8906, "herb")],
        "wait_s":  20,
    },
    "heist": {
        "html":    "heist_web.html",
        "script":  "heist_demo.lex",
        "stalls": [(8900, ""), (8901, "heist_lobby"), (8902, "heist_security"),
                   (8903, "heist_server"), (8904, "heist_vault")],
        "wait_s":  15,
    },
    "station": {
        "html":    "station_web.html",
        "script":  "station_demo.lex",
        "stalls": [(8900, ""), (8901, "station_life_support"), (8902, "station_navigation"),
                   (8903, "station_comms"), (8904, "station_cargo")],
        "wait_s":  15,
    },
    "trading": {
        "html":    "trading_web.html",
        "script":  "trading_demo.lex",
        "stalls": [(8900, ""), (8901, "trading_quantum"),
                   (8902, "trading_solar"), (8903, "trading_water")],
        "wait_s":  15,
    },
    "triage": {
        "html":    "triage_web.html",
        "script":  "triage_demo.lex",
        "stalls": [(8900, ""), (8901, "triage_zone_alpha"), (8902, "triage_zone_beta"),
                   (8903, "triage_zone_gamma"), (8904, "triage_hospital_hq")],
        "wait_s":  15,
    },
}


# ── Helpers ───────────────────────────────────────────────────────────────────

def wait_healthy(port: int, retries: int = 30) -> bool:
    for _ in range(retries):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1)
            return True
        except Exception:
            time.sleep(0.5)
    return False


def kill_ports(*ports):
    for port in ports:
        subprocess.run(
            f"lsof -ti:{port} | xargs kill -9 2>/dev/null; true",
            shell=True, capture_output=True,
        )


def webm_to_gif(webm: Path, gif: Path, fps: int = 3, width: int = 640,
                clip_to: float | None = None):
    """Convert WebM to palette-optimised GIF. clip_to trims to N seconds."""
    palette = gif.with_suffix(".palette.png")
    trim = ["-to", str(clip_to)] if clip_to else []
    vf_gen = f"fps={fps},scale={width}:-1:flags=lanczos,palettegen=stats_mode=diff"
    vf_use = f"fps={fps},scale={width}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer"
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(webm)] + trim + ["-vf", vf_gen, str(palette)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(webm)] + trim + ["-i", str(palette),
         "-filter_complex", vf_use, "-loop", "0", str(gif)],
        check=True, capture_output=True,
    )
    palette.unlink(missing_ok=True)
    size_mb = gif.stat().st_size / 1_048_576
    print(f"  GIF  → {gif}  ({size_mb:.1f} MB)")


# ── Core recording logic ──────────────────────────────────────────────────────

def record_demo(name: str, cfg: dict, base_env: dict):
    print(f"\n{'='*60}")
    print(f"  Recording: {name}")
    print(f"{'='*60}")

    stalls = cfg["stalls"]
    ports  = [s[0] for s in stalls]
    kill_ports(*ports)
    time.sleep(1)

    procs = []
    for port, stall in stalls:
        e = dict(base_env,
                 LEX_ROBOT_SIDECAR_PORT=str(port),
                 LEX_ROBOT_REPO_ROOT=str(REPO),
                 LEX_DASHBOARD_HTML=cfg["html"])
        if stall:
            e["LEX_STALL_NAME"] = stall
        p = subprocess.Popen(
            LEX_RUN + [SIDECAR, "run"],
            env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        procs.append(p)

    for port in ports:
        if not wait_healthy(port):
            print(f"ERROR: sidecar on :{port} did not start")
            for p in procs: p.terminate()
            return
    print(f"  Sidecars healthy: {ports}")

    video_dir = DEMOS / f"_tmp_{name}"
    video_dir.mkdir(exist_ok=True)
    webm_out  = DEMOS / f"{name}.webm"
    gif_out   = DEMOS / f"{name}.gif"

    try:
        with sync_playwright() as pw:
            browser = pw.chromium.launch(headless=False)
            ctx = browser.new_context(
                viewport={"width": 1440, "height": 900},
                record_video_dir=str(video_dir),
                record_video_size={"width": 1440, "height": 900},
            )
            page = ctx.new_page()
            page.goto("http://localhost:8900")
            time.sleep(2)  # let SSE connect and initial state render

            print(f"  Dashboard open — running {cfg['script']} …")
            demo = subprocess.Popen(
                ["lex", "run", "--allow-effects",
                 "env,fs_write,io,llm,net,proc,sense,sql,time",
                 str(REPO / "examples" / cfg["script"]), "run"],
                env=base_env,
            )
            demo.wait()
            print(f"  Demo finished — waiting {cfg['wait_s']}s for dashboard …")
            time.sleep(cfg["wait_s"])

            page.close()
            ctx.close()
            browser.close()

        videos = sorted(video_dir.glob("*.webm"), key=lambda p: p.stat().st_mtime, reverse=True)
        if not videos:
            print("  ERROR: no video generated")
            return

        shutil.move(str(videos[0]), str(webm_out))
        size_mb = webm_out.stat().st_size / 1_048_576
        print(f"  WebM → {webm_out}  ({size_mb:.1f} MB)")

        print("  Converting to GIF …")
        # Heist has 2×60 s human-escalation timeouts — clip to first 65 s
        clip = 65.0 if name == "heist" else None
        webm_to_gif(webm_out, gif_out, clip_to=clip)

    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try: p.wait(timeout=3)
            except subprocess.TimeoutExpired: p.kill()
        shutil.rmtree(video_dir, ignore_errors=True)
        kill_ports(*ports)
        print(f"  Sidecars stopped.")


# ── Entry point ───────────────────────────────────────────────────────────────

def main():
    env = os.environ.copy()
    if not env.get("VERTEX_ACCESS_TOKEN"):
        sys.exit("ERROR: set VERTEX_ACCESS_TOKEN (e.g. gcloud auth print-access-token)")
    if not env.get("VERTEX_PROJECT"):
        sys.exit("ERROR: set VERTEX_PROJECT (e.g. elusmart-dev)")
    env.setdefault("VERTEX_LOCATION", "eu")

    DEMOS.mkdir(exist_ok=True)

    target = sys.argv[1] if len(sys.argv) > 1 else "all"
    if target == "all":
        names = list(DEMOS_CFG.keys())
    elif target in DEMOS_CFG:
        names = [target]
    else:
        sys.exit(f"Unknown demo '{target}'. Choose: {' | '.join(DEMOS_CFG)} | all")

    for name in names:
        record_demo(name, DEMOS_CFG[name], env)
        time.sleep(3)

    print("\nDone. Files in demos/:")
    for f in sorted(DEMOS.glob("*.webm")) + sorted(DEMOS.glob("*.gif")):
        print(f"  {f.name:30s}  {f.stat().st_size/1_048_576:.1f} MB")


if __name__ == "__main__":
    main()
