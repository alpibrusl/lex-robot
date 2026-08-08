# lex-robot — convenience targets. The five governance demos need only `lex` +
# python3 (no pip). The ML demos (keep-out / MuJoCo / learned policy) need the
# Python deps in sidecar/requirements.txt — see the README dependency matrix.

.PHONY: help check smoke demo grant task budget depot xlerobot xlerobot-task xlerobot-voice xlerobot-sim xlerobot-find xlerobot-find-sim keepout dynamic_keepout tool_fire mcp-grant a2a-grant xlerobot-rl-train xlerobot-rl-run xlerobot-rl-usage xlerobot-rl-finetune xlerobot-llm-mock xlerobot-llm fleet-clean-house bazaar-visit skill-acquisition skill-catalog deps clean

help: ## Show this help
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort

check: ## Type-check all src + example programs
	@for f in src/*.lex examples/*.lex tests/*.lex; do lex check $$f >/dev/null && echo "ok  $$f"; done

smoke: ## Run the zero-dep smoke test (check + 5 demos, asserts output)
	@bash scripts/smoke.sh

demo: ## Hero demo: untrusted LLM planner, Lex on the rails (no ML deps)
	@bash scripts/demo.sh llm

grant: ## Grant gate: in-bounds allowed, out-of-bounds denied (no ML deps)
	@bash scripts/demo.sh grant

task: ## Evidence-gated Perceive->Plan->Execute->Verify graph (no ML deps)
	@bash scripts/demo.sh task

budget: ## Budget supervisor: a zero-action grant kills the run (no ML deps)
	@bash scripts/demo.sh budget

depot: ## OCPP-gated depot connect demo, stub sidecar (no ML deps)
	@bash scripts/demo.sh depot

xlerobot: ## XLeRobot dual-arm + base governance demo, stub sidecar (no ML deps)
	@bash scripts/demo.sh xlerobot

xlerobot-task: ## Fetch-the-Cup as a VERIFIED robot_task: trail -> referee -> ranked (no ML deps)
	@bash scripts/demo.sh xlerobot_task

xlerobot-voice: ## Voice goal + camera + mic-refusal: sensors as granted capabilities (no ML deps)
	@bash scripts/demo.sh xlerobot_voice

xlerobot-sim: ## Same demo against real MuJoCo physics (NEEDS: pip install mujoco numpy)
	@python3 sidecar/xlerobot_mujoco_sidecar.py & echo $$! > /tmp/lex-robot-xle.pid; \
	 for i in $$(seq 1 100); do curl -sf http://127.0.0.1:8900/health >/dev/null 2>&1 && break; \
	   kill -0 `cat /tmp/lex-robot-xle.pid` 2>/dev/null || { echo "sidecar died (pip install mujoco numpy?)"; exit 1; }; sleep 0.2; done; \
	 lex run --allow-effects net,sense,actuate,io examples/xlerobot_demo.lex run; \
	 kill `cat /tmp/lex-robot-xle.pid` 2>/dev/null || true

xlerobot-find: ## "Bring me the cup": vision-grounded fetch via locate_object, stub sidecar (no ML deps)
	@bash scripts/demo.sh xlerobot_find

xlerobot-find-sim: ## Same find-and-fetch demo against real MuJoCo physics + real color-detection vision (NEEDS: pip install mujoco numpy)
	@python3 sidecar/xlerobot_mujoco_sidecar.py & echo $$! > /tmp/lex-robot-xle.pid; \
	 for i in $$(seq 1 100); do curl -sf http://127.0.0.1:8900/health >/dev/null 2>&1 && break; \
	   kill -0 `cat /tmp/lex-robot-xle.pid` 2>/dev/null || { echo "sidecar died (pip install mujoco numpy?)"; exit 1; }; sleep 0.2; done; \
	 lex run --allow-effects net,sense,actuate,io examples/find_and_fetch_demo.lex run; \
	 kill `cat /tmp/lex-robot-xle.pid` 2>/dev/null || true

deps: ## Install the Python deps for the ML demos (gym / mujoco / torch)
	pip install -r sidecar/requirements.txt

keepout: ## Keep-out demo (NEEDS ML deps: gymnasium + gym-pusht + lerobot)
	@python3 sidecar/gym_sidecar.py & echo $$! > /tmp/lex-robot-gym.pid; sleep 6; \
	 lex run --allow-effects net,io examples/safe_rollout.lex run; \
	 kill `cat /tmp/lex-robot-gym.pid` 2>/dev/null || true

dynamic_keepout: ## Dynamic human keep-out: live-updating no-go zone (no ML deps)
	@bash scripts/demo.sh dynamic_keepout

tool_fire: ## Dangerous-tool fire-only-in-bounds: grant blocks out-of-zone + unclamped (no ML deps)
	@bash scripts/demo.sh tool_fire

mcp-grant: ## MCP grant gate smoke test (deny/allow/clamp/budget-kill, no sidecar needed)
	@bash scripts/demo.sh mcp_grant

a2a-grant: ## A2A grant gate smoke test: same skills over standard Google A2A (no sidecar needed)
	@bash scripts/demo.sh a2a_grant

xlerobot-llm-mock: ## LLM planner tool-dispatch, verified for real with a scripted mock model (no API key, no ML deps)
	@bash scripts/llm_planner_mock_test.sh

xlerobot-llm: ## "Bring me the cup", spoken + a REAL OpenCode-backed plan (NEEDS: OPENCODE_API_KEY; GOAL="..." for a typed goal)
	@python3 sidecar/xlerobot_sidecar.py & echo $$! > /tmp/lex-robot-xle-llm-sc.pid; \
	 lex run --allow-effects io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate \
	   examples/a2a_robot_demo.lex run & echo $$! > /tmp/lex-robot-xle-llm-a2a.pid; \
	 for i in $$(seq 1 100); do curl -sf http://127.0.0.1:8900/health >/dev/null 2>&1 && curl -sf http://127.0.0.1:8766/.well-known/agent.json >/dev/null 2>&1 && break; sleep 0.2; done; \
	 EFF=io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,sense,actuate,env,stream; \
	 if [ -n "$$GOAL" ]; then \
	   lex run --allow-effects $$EFF examples/llm_command_demo.lex run_text "\"$$GOAL\""; \
	 else \
	   lex run --allow-effects $$EFF examples/llm_command_demo.lex run; \
	 fi; \
	 kill `cat /tmp/lex-robot-xle-llm-sc.pid` `cat /tmp/lex-robot-xle-llm-a2a.pid` 2>/dev/null || true

xlerobot-rl-train: ## Train a real PPO policy against LexXLeRobotFetch-v0 (NEEDS: pip install stable-baselines3)
	@python3 sidecar/xlerobot_rl_train.py

xlerobot-rl-usage: ## Summarize a real trail's denial pattern into a retraining signal (no ML deps)
	@python3 gym_env/xlerobot_usage_log.py $(TRAIL)

xlerobot-rl-finetune: ## Retrain an existing policy from a real rollout's usage log (NEEDS: pip install stable-baselines3)
	@python3 sidecar/xlerobot_rl_finetune.py $(MODEL) --usage-log $(USAGE_LOG)

xlerobot-rl-run: ## Trained-policy safe-RL/eval loop: train* -> roll out -> verify -> reputation (no venv: replays a fixture)
	@bash examples/xlerobot_rl_run.sh

fleet-clean-house: ## Closed 5-robot home fleet claims one room each via the fleet_traffic arbiter (no ML deps)
	@bash examples/fleet_clean_house_run.sh

bazaar-visit: ## A robot claims physical space near a bazaar stall it's never met, then verifies+transacts (no ML deps)
	@bash examples/bazaar_visit_demo_run.sh

skill-acquisition: ## A robot registers + calls a new INFORMATIONAL skill at runtime via lex tool-registry (no ML deps)
	@bash examples/skill_acquisition_demo_run.sh

skill-catalog: ## Registers + calls all 10 proposed informational skills from skill_library.lex (no ML deps)
	@bash examples/skill_catalog_demo_run.sh

clean: ## Remove stray run artifacts
	@rm -f MUJOCO_LOG.TXT /tmp/lex-robot-*.log
