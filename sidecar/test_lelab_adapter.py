import lelab_adapter as ad


LEFT = {"names": ["left_shoulder_pan", "left_shoulder_lift", "left_elbow_flex",
                  "left_wrist_flex", "left_wrist_roll", "left_gripper"],
        "positions": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0], "velocities": [0.0] * 6}
RIGHT = dict(LEFT, names=[n.replace("left_", "right_") for n in LEFT["names"]],
             positions=[7.0, 8.0, 9.0, 10.0, 11.0, 12.0])


# ---- joint translation ----------------------------------------------------

def test_joint_names_are_translated_to_the_urdf_vocabulary_leLab_renders():
    out = ad.joint_positions_payload({"left": LEFT, "right": RIGHT}, now=1.0)
    assert out["success"] is True
    assert out["joint_positions"]["left_Rotation"] == 1.0
    assert out["joint_positions"]["left_Jaw"] == 6.0
    assert out["joint_positions"]["right_Wrist_Pitch"] == 10.0
    assert out["timestamp"] == 1.0


def test_both_arms_are_returned_rather_than_one_silently_dropped():
    out = ad.joint_positions_payload({"left": LEFT, "right": RIGHT}, now=0.0)
    assert len(out["joint_positions"]) == 12


def test_a_missing_arm_is_reported_not_hidden():
    out = ad.joint_positions_payload(
        {"left": LEFT, "right": {"error": "right arm not configured -- partial build"}}, now=0.0)
    assert out["success"] is False
    assert "partial build" in out["errors"]["right"]
    assert len(out["joint_positions"]) == 6      # what IS there still comes back


def test_unknown_motor_names_pass_through_untranslated():
    reply = {"names": ["left_seventh_axis"], "positions": [0.5]}
    out = ad.joint_positions_payload({"left": reply}, now=0.0)
    assert out["joint_positions"]["left_seventh_axis"] == 0.5


# ---- move-arm -------------------------------------------------------------

def test_leader_follower_teleoperation_is_refused_with_a_reason():
    args, refused = ad.move_arm_request(
        {"leader_port": "/dev/ttyA", "follower_port": "/dev/ttyB",
         "leader_config": "so101", "follower_config": "so101"})
    assert args is None
    assert "no leader arm" in refused


def test_an_absolute_target_becomes_a_move_arm_call():
    args, refused = ad.move_arm_request({"arm": "right", "x": 0.2, "y": -0.1, "z": 0.3})
    assert refused is None
    assert args == {"arm": "right", "x": 0.2, "y": -0.1, "z": 0.3}


def test_a_target_missing_an_axis_is_refused_rather_than_defaulted():
    # Defaulting z to 0 would silently drive the arm to the floor.
    args, refused = ad.move_arm_request({"arm": "left", "x": 0.2, "y": 0.1})
    assert args is None and "missing z" in refused


def test_a_bad_arm_or_a_non_numeric_target_is_refused():
    assert ad.move_arm_request({"arm": "third", "x": 1, "y": 1, "z": 1})[0] is None
    assert ad.move_arm_request({"x": "over there", "y": 1, "z": 1})[0] is None
    assert ad.move_arm_request("not a dict")[0] is None


# ---- recording ------------------------------------------------------------

def test_a_recording_request_becomes_teach_start_args():
    args, refused = ad.start_recording_request({
        "dataset_repo_id": "local/picks", "single_task": "pick the cup",
        "fps": 30, "episode_time_s": 45, "tags": ["nominal"],
        "cameras": {"head": {}, "left": {}}, "num_episodes": 1})
    assert refused is None
    assert args["name"] == "local_picks"          # a repo id is not a filename
    assert args["task"] == "pick the cup"
    assert args["fps"] == 30 and args["seconds"] == 45
    assert args["cameras"] == ["head", "left"]


def test_multi_episode_recording_is_refused_not_silently_reduced_to_one():
    args, refused = ad.start_recording_request({"dataset_repo_id": "d", "num_episodes": 5})
    assert args is None and "ONE demonstration" in refused


def test_push_to_hub_is_refused_as_lerobots_job():
    args, refused = ad.start_recording_request({"dataset_repo_id": "d", "push_to_hub": True})
    assert args is None and "Hub upload" in refused


def test_recording_status_maps_an_active_teach_session():
    out = ad.recording_status_payload(
        {"recording": True, "frames": 120, "arm": "left", "elapsed_s": 6.0,
         "name": "picks", "error": None}, "local/picks")
    assert out["recording_active"] is True
    assert out["current_phase"] == "recording"
    assert out["available_controls"] == {"stop_recording": True, "exit_early": True,
                                         "rerecord_episode": False}
    assert out["current_episode"] == 1 and out["total_episodes"] == 1
    assert out["dataset_repo_id"] == "local/picks"


def test_recording_status_surfaces_a_teach_error_as_the_error_phase():
    out = ad.recording_status_payload({"recording": False, "error": "servo dropped out"})
    assert out["current_phase"] == "error" and out["error"] == "servo dropped out"


def test_recording_status_of_an_idle_recorder():
    out = ad.recording_status_payload({"recording": False, "frames": 0})
    assert out["recording_active"] is False and out["message"] == "idle"
    assert out["available_controls"]["stop_recording"] is False


def test_datasets_are_labelled_with_where_they_came_from():
    out = ad.datasets_payload({"recordings": [
        {"name": "picks", "task": "pick the cup", "arm": "left", "frames": 240,
         "duration_s": 12.0, "created_at": "2026-08-25T10:00:00"}]})
    d = out["datasets"][0]
    assert d["repo_id"] == "picks" and d["source"] == "lex-robot/teach"
    assert d["frames"] == 240 and d["duration_s"] == 12.0


def test_an_unreadable_recording_keeps_its_error():
    out = ad.datasets_payload({"recordings": [{"name": "broken", "error": "unreadable: bad json"}]})
    assert out["datasets"][0]["error"].startswith("unreadable")


def test_no_recordings_is_an_empty_list_not_a_failure():
    assert ad.datasets_payload({"recordings": []}) == {"datasets": []}
    assert ad.datasets_payload({}) == {"datasets": []}


# ---- the refusal table ----------------------------------------------------

def test_training_and_upload_are_refused_as_not_this_layer():
    assert "not lex-robot's layer" in ad.refusal_for("/jobs/training")
    assert "not lex-robot's layer" in ad.refusal_for("/upload-dataset")
    assert "not lex-robot's layer" in ad.refusal_for("/system/cuda-status")


def test_a_refusal_covers_every_subpath_of_its_prefix():
    assert ad.refusal_for("/jobs/17/logs") == ad.refusal_for("/jobs")
    assert ad.refusal_for("/hf-auth/login") is not None


def test_calibration_is_refused_because_no_skill_expresses_it():
    reason = ad.refusal_for("/start-calibration")
    assert "no calibration skill" in reason
    assert "second path to the servos" in reason


def test_served_routes_are_not_in_the_refusal_table():
    for _method, path in ad.IMPLEMENTED:
        base = path.split("/{", 1)[0]
        assert ad.refusal_for(base) is None, f"{path} is both implemented and refused"


def test_routes_payload_lists_both_halves_so_a_ui_can_be_pointed_at_it():
    p = ad.routes_payload()
    served = {r["path"] for r in p["implemented"]}
    assert "/joint-positions" in served and "/move-arm" in served
    assert any(r["path"] == "/jobs" for r in p["refused"])
    assert p["sidecar"].startswith("http://127.0.0.1:")


# ---- cameras --------------------------------------------------------------

def test_a_camera_that_returns_no_frame_is_not_listed_as_available():
    # The Tier-1 stub answers every read_camera with 640x480 and no JPEG.
    out = ad.cameras_payload({"head": {"width": 640, "height": 480, "jpeg_b64": ""}})
    assert out["cameras"] == []
    assert out["unavailable"][0]["name"] == "head"


def test_a_live_camera_is_listed_with_its_feed_url():
    out = ad.cameras_payload({"head": {"width": 1280, "height": 720, "jpeg_b64": "/9j/4AA"}})
    assert out["cameras"] == [{"name": "head", "width": 1280, "height": 720,
                               "feed": "/camera-feed/head"}]
    assert "unavailable" not in out


def test_an_unconfigured_camera_keeps_the_sidecars_reason():
    out = ad.cameras_payload({"left": {"error": "camera 'left' not configured"}})
    assert out["cameras"] == []
    assert "not configured" in out["unavailable"][0]["detail"]
