# Live game-server (referee) image for the A2A games platform.
# Built on the proven lex-loom container pattern: install the lex binary, swap in
# the referee-only manifest, warm the dep cache, then run sim_sidecar as the
# dashboard/referee. Remote player agents connect over A2A and play; every move
# is recorded to the hash-chained trail.
FROM ubuntu:24.04

ARG LEX_VERSION=0.9.13

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git ca-certificates tar python3 \
    && rm -rf /var/lib/apt/lists/*

RUN set -e; \
    ARCH=$(uname -m); \
    case "$ARCH" in \
      x86_64)  TRIPLE="x86_64-unknown-linux-gnu" ;; \
      aarch64) TRIPLE="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac; \
    URL="https://github.com/alpibrusl/lex-lang/releases/download/v${LEX_VERSION}/lex-v${LEX_VERSION}-${TRIPLE}.tar.gz"; \
    curl -fsSL "$URL" -o /tmp/lex.tar.gz; \
    tar -xzf /tmp/lex.tar.gz -C /tmp; \
    mv /tmp/lex-v${LEX_VERSION}-${TRIPLE}/lex /usr/local/bin/lex; \
    chmod +x /usr/local/bin/lex; rm /tmp/lex.tar.gz

WORKDIR /app
COPY . .

# Referee-only manifest (drops lex-jobs/lex-guard, which the referee never imports).
RUN cp deploy/lex.toml lex.toml

# Resolve deps; the private packages need a GitHub token mounted as a build secret.
RUN --mount=type=secret,id=github_token \
    TOKEN=$(cat /run/secrets/github_token 2>/dev/null || true); \
    if [ -n "$TOKEN" ]; then git config --global url."https://${TOKEN}@github.com/".insteadOf "https://github.com/"; fi; \
    lex pkg install; \
    git config --global --unset-all 'url.https://github.com/.insteadof' 2>/dev/null || true

# Fail the build if the referee doesn't type-check (catch dep drift at build time,
# not container start).
RUN lex check sidecar/sim_sidecar.lex

EXPOSE 8900
ENV LEX_ROBOT_SIDECAR_PORT=8900 \
    LEX_ROBOT_REPO_ROOT=/app \
    LEX_DASHBOARD_HTML=games_lobby.html

# The dashboard/referee: serves the web UI + hosts every game's skills + SSE.
CMD ["sh","-c","lex run --allow-effects concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time --allow-proc sh sidecar/sim_sidecar.lex run"]
