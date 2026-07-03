# lex-robot — convenience targets. The five governance demos need only `lex` +
# python3 (no pip). The ML demos (keep-out / MuJoCo / learned policy) need the
# Python deps in sidecar/requirements.txt — see the README dependency matrix.

.PHONY: help check smoke demo grant task budget depot xlerobot xlerobot-task xlerobot-sim keepout dynamic_keepout tool_fire mcp-grant deps clean

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

xlerobot-sim: ## Same demo against real MuJoCo physics (NEEDS: pip install mujoco numpy)
	@python3 sidecar/xlerobot_mujoco_sidecar.py & echo $$! > /tmp/lex-robot-xle.pid; \
	 for i in $$(seq 1 100); do curl -sf http://127.0.0.1:8900/health >/dev/null 2>&1 && break; \
	   kill -0 `cat /tmp/lex-robot-xle.pid` 2>/dev/null || { echo "sidecar died (pip install mujoco numpy?)"; exit 1; }; sleep 0.2; done; \
	 lex run --allow-effects net,sense,actuate,io examples/xlerobot_demo.lex run; \
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

clean: ## Remove stray run artifacts
	@rm -f MUJOCO_LOG.TXT /tmp/lex-robot-*.log
