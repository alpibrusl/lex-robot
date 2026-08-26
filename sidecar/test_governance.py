import json

import governance as gov
from trail import compute_id


GRANT = {
    "arms": {
        "left": {"workspace_m": [{"min": 0.05, "max": 0.45}, {"min": 0.0, "max": 0.35},
                                 {"min": 0.0, "max": 0.5}],
                 "max_velocity_mps": 0.25, "max_force_n": 15.0},
    },
    "grippers": {"left": {"max_grip_force_n": 15.0}},
    "bases": {"base": {"floor_area_m": [{"min": 0.0, "max": 4.0}, {"min": 0.0, "max": 3.0}],
                       "max_speed_mps": 0.5}},
}
FIRMWARE = {"max_grip_n": 20.0, "max_speed_mps": 0.4}


def clock():
    """Deterministic, strictly increasing — real time would make ids unstable."""
    clock.t += 0.001
    return clock.t


clock.t = 1_700_000_000.0


# ---- categories -----------------------------------------------------------

def test_polling_reads_are_not_recorded_by_default():
    led = gov.Ledger(clock=clock)
    assert led.record("read_joints", {"arm": "left"}, {"positions": [0] * 6}) is None
    assert led.record("read_arm_pose", {"arm": "left"}, {"ok": True, "x": 0.1}) is None
    assert led.snapshot()["recorded"] == 0


def test_reads_are_recorded_when_asked_for():
    led = gov.Ledger(include_reads=True, clock=clock)
    assert led.record("read_joints", {"arm": "left"}, {"positions": []}) is not None


def test_unknown_skill_is_recorded_not_dropped():
    # A capability the table has never heard of is exactly what an audit is for.
    led = gov.Ledger(clock=clock)
    d = led.record("launch_missile", {}, {"outcome": "reached"})
    assert d is not None and d["category"] == "unknown"


# ---- classification -------------------------------------------------------

def test_workspace_refusal_reads_as_denied():
    v = gov.classify("move_arm", {"arm": "left", "x": 9.0},
                     {"outcome": "denied", "detail": "x=9.000 outside granted workspace"}, GRANT)
    assert v["verdict"] == "denied"
    assert "outside granted workspace" in v["reason"]


def test_grip_force_over_the_grant_reads_as_clamped():
    v = gov.classify("grasp_arm", {"arm": "left", "force": 40.0},
                     {"outcome": "reached", "detail": "left gripper closed"}, GRANT, FIRMWARE)
    assert v["verdict"] == "clamped"
    assert v["clamps"][0] == {"bound": "grippers.left.max_grip_force_n", "source": "grant",
                              "requested": 40.0, "ceiling": 15.0}


def test_grip_force_inside_the_grant_is_plain_allowed():
    v = gov.classify("grasp_arm", {"arm": "left", "force": 10.0},
                     {"outcome": "reached"}, GRANT, FIRMWARE)
    assert v["verdict"] == "allowed" and v["clamps"] == []


def test_base_speed_clamp_is_attributed_to_the_ceiling_that_bound_it():
    # move_base applies the grant ceiling first, then the firmware floor. The
    # grant's 0.5 is tighter than the firmware's 0.4? No -- 0.4 is tighter, so
    # the firmware floor is what the request actually hit.
    v = gov.classify("move_base", {"x": 1.0, "y": 0.0, "speed": 2.0},
                     {"outcome": "reached"}, GRANT, FIRMWARE)
    assert v["verdict"] == "clamped"
    assert v["clamps"][0]["source"] == "firmware"
    assert v["clamps"][0]["ceiling"] == 0.4


def test_a_grant_tighter_than_the_firmware_floor_is_attributed_to_the_grant():
    v = gov.classify("move_base", {"speed": 2.0}, {"outcome": "reached"},
                     GRANT, {"max_speed_mps": 1.0})
    assert v["clamps"][0] == {"bound": "bases.base.max_speed_mps", "source": "grant",
                              "requested": 2.0, "ceiling": 0.5}


def test_a_base_speed_under_every_ceiling_is_plain_allowed():
    v = gov.classify("move_base", {"speed": 0.3}, {"outcome": "reached"}, GRANT, FIRMWARE)
    assert v["verdict"] == "allowed" and v["clamps"] == []


def test_a_floor_area_refusal_reads_as_denied():
    v = gov.classify("move_base", {"x": 9.0, "y": 1.0, "speed": 0.3},
                     {"outcome": "denied", "detail": "x=9.000 outside granted floor area"},
                     GRANT, FIRMWARE)
    assert v["verdict"] == "denied"
    assert "outside granted floor area" in v["reason"]


def test_stall_and_error_read_as_failed():
    assert gov.classify("move_arm", {}, {"outcome": "stalled", "detail": "bus busy"})["verdict"] == "failed"
    assert gov.classify("read_camera", {}, {"error": "no camera"})["verdict"] == "failed"
    assert gov.classify("teach_start", {}, {"ok": False, "detail": "already recording"})["verdict"] == "failed"


def test_unreadable_results_say_unknown_rather_than_guessing():
    assert gov.classify("move_arm", {}, {})["verdict"] == "unknown"
    assert gov.classify("move_arm", {}, "nope")["verdict"] == "unknown"


# ---- honesty about what is actually enforced ------------------------------

def test_grant_enforcement_reports_which_bounds_this_sidecar_checks():
    rows = {r["bound"]: r for r in gov.grant_enforcement(GRANT)}
    assert rows["arms.left.workspace_m"]["enforced"] is True
    assert rows["grippers.left.max_grip_force_n"]["enforced"] is True
    assert rows["bases.base.floor_area_m"]["enforced"] is True
    assert rows["bases.base.max_speed_mps"]["enforced"] is True
    # Still declared-only, and still said so rather than implied enforced.
    assert rows["arms.left.max_velocity_mps"]["enforced"] is False
    assert rows["arms.left.max_force_n"]["enforced"] is False


def test_two_bases_are_ambiguous_so_neither_is_claimed_as_enforced():
    # The sidecar refuses to guess which envelope binds its one base; the
    # ledger must not claim an envelope the code declines to apply.
    grant = {"bases": {"left_base": {"max_speed_mps": 0.5},
                       "right_base": {"max_speed_mps": 0.9}}}
    rows = gov.grant_enforcement(grant)
    assert rows and all(r["enforced"] is False for r in rows)
    assert gov.base_entry(grant["bases"]) == (None, None)


def test_a_single_differently_named_base_still_binds():
    grant = {"bases": {"cart": {"floor_area_m": [{"min": 0.0, "max": 2.0},
                                                 {"min": 0.0, "max": 2.0}]}}}
    rows = {r["bound"]: r for r in gov.grant_enforcement(grant)}
    assert rows["bases.cart.floor_area_m"]["enforced"] is True


def test_no_grant_means_no_rows_rather_than_invented_ones():
    assert gov.grant_enforcement(None) == []


# ---- argument summarising -------------------------------------------------

def test_camera_frames_and_transcripts_never_reach_the_page():
    out = gov.summarize_args({"jpeg_b64": "A" * 5000, "transcript": "bring me the cup",
                              "name": "head"})
    assert out["jpeg_b64"] == "<jpeg_b64 redacted>"
    assert out["transcript"] == "<transcript redacted>"
    assert out["name"] == "head"


def test_long_strings_and_lists_are_truncated():
    out = gov.summarize_args({"text": "x" * 500, "tags": list(range(20))})
    assert len(out["text"]) == gov._MAX_ARG_CHARS + 1
    assert out["tags"][-1] == "…+12"


# ---- the chain ------------------------------------------------------------

def test_each_decision_emits_an_invoked_completed_pair_that_chains():
    led = gov.Ledger(clock=clock)
    d1 = led.record("move_arm", {"arm": "left", "x": 0.2}, {"outcome": "reached"}, GRANT)
    d2 = led.record("grasp_arm", {"arm": "left", "force": 5.0}, {"outcome": "reached"}, GRANT)
    events = list(led.chain.events)
    assert [e["kind"] for e in events] == ["cap.invoked", "cap.completed"] * 2
    assert events[1]["parent"] == events[0]["id"]
    assert events[2]["parent"] == events[1]["id"]
    assert d1["completed_id"] == events[1]["id"]
    assert d2["invoked_id"] == events[2]["id"]
    assert led.chain.verify()["ok"]


def test_ids_match_lex_trails_own_formula():
    led = gov.Ledger(clock=clock)
    led.record("move_arm", {"arm": "left"}, {"outcome": "reached"})
    e = list(led.chain.events)[0]
    assert e["id"] == compute_id(e["kind"], e["parent"], e["payload_json"], e["ts_ms"])


def test_tampering_with_a_retained_event_is_caught():
    led = gov.Ledger(clock=clock)
    led.record("move_arm", {"arm": "left"}, {"outcome": "reached"})
    list(led.chain.events)[0]["payload_json"] = '{"capability":"nothing"}'
    v = led.chain.verify()
    assert not v["ok"] and "id mismatch" in v["detail"]


def test_eviction_keeps_a_checkpoint_so_the_window_still_verifies():
    led = gov.Ledger(window=4, clock=clock)
    for i in range(5):
        led.record("move_arm", {"i": i}, {"outcome": "reached"})
    assert led.chain.total == 10
    assert len(led.chain.events) == 4
    assert led.chain.checkpoint is not None
    assert led.chain.verify()["ok"]
    assert list(led.chain.events)[0]["parent"] == led.chain.checkpoint


def test_evicted_events_survive_on_disk_when_a_trail_path_is_set(tmp_path):
    path = tmp_path / "trail.jsonl"
    led = gov.Ledger(window=2, path=str(path), clock=clock)
    for i in range(3):
        led.record("move_arm", {"i": i}, {"outcome": "reached"})
    lines = path.read_text().strip().splitlines()
    assert len(lines) == 6                      # nothing dropped from the file
    assert json.loads(lines[0])["kind"] == "cap.invoked"
    assert led.chain.write_error is None


def test_an_unwritable_trail_path_is_surfaced_not_swallowed(tmp_path):
    led = gov.Ledger(path=str(tmp_path / "no-such-dir" / "trail.jsonl"), clock=clock)
    led.record("move_arm", {}, {"outcome": "reached"})
    assert led.chain.write_error                 # shown on the page
    assert led.chain.verify()["ok"]              # and the robot kept working


def test_timestamps_strictly_increase_even_inside_one_millisecond():
    led = gov.Ledger(clock=lambda: 1_700_000_000.0)
    for _ in range(3):
        led.record("move_arm", {}, {"outcome": "reached"})
    ts = [e["ts_ms"] for e in led.chain.events]
    assert ts == sorted(set(ts))


# ---- snapshot -------------------------------------------------------------

def test_snapshot_counts_by_verdict_and_by_capability():
    led = gov.Ledger(clock=clock)
    led.record("move_arm", {"arm": "left", "x": 9.0}, {"outcome": "denied", "detail": "out"}, GRANT)
    led.record("move_arm", {"arm": "left", "x": 0.2}, {"outcome": "reached"}, GRANT)
    led.record("grasp_arm", {"arm": "left", "force": 40.0}, {"outcome": "reached"}, GRANT)
    snap = led.snapshot()
    assert snap["counters"]["denied"] == 1
    assert snap["counters"]["allowed"] == 1
    assert snap["counters"]["clamped"] == 1
    assert snap["by_capability"]["move_arm"]["denied"] == 1
    assert snap["chain"]["total_events"] == 6
    assert snap["chain"]["verified"]["ok"]


def test_snapshot_retains_only_the_most_recent_decisions():
    led = gov.Ledger(max_decisions=3, clock=clock)
    for i in range(10):
        led.record("move_arm", {"i": i}, {"outcome": "reached"})
    snap = led.snapshot()
    assert snap["recorded"] == 10 and snap["retained"] == 3
    assert [d["args"]["i"] for d in snap["decisions"]] == [7, 8, 9]


def test_ledger_from_env_reads_the_documented_knobs():
    led = gov.ledger_from_env({"LEX_XLE_LEDGER_MAX": "7", "LEX_XLE_TRAIL_WINDOW": "9",
                               "LEX_XLE_LEDGER_READS": "1"})
    assert led.decisions.maxlen == 7 and led.chain.window == 9 and led.include_reads
    assert gov.ledger_from_env({}).include_reads is False


# ---- concurrency ----------------------------------------------------------

def test_concurrent_records_produce_one_unbroken_chain():
    # The sidecar is a ThreadingHTTPServer: two skill calls really do complete
    # at once, and an unlocked read-hash-store would give two events the same
    # parent -- a chain broken on arrival.
    import threading

    led = gov.Ledger(max_decisions=1000, window=4000)
    def hammer(n):
        for i in range(n):
            led.record("move_arm", {"i": i}, {"outcome": "reached"})
    threads = [threading.Thread(target=hammer, args=(50,)) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert led.chain.total == 800
    assert led.chain.verify()["ok"]
    assert sum(led.counters.values()) == 400
    assert len({d["seq"] for d in led.decisions}) == 400


def test_an_invoked_completed_pair_is_never_split_by_another_thread():
    import threading

    led = gov.Ledger(max_decisions=1000, window=4000)
    def hammer():
        for _ in range(40):
            led.record("grasp_arm", {"arm": "left", "force": 5.0}, {"outcome": "reached"})
    threads = [threading.Thread(target=hammer) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    kinds = [e["kind"] for e in led.chain.events]
    assert kinds == ["cap.invoked", "cap.completed"] * (len(kinds) // 2)
