# Reproducible lex-robot demo image: the published `lex` toolchain + python3 +
# this repo. Runs the four zero-dependency governance demos out of the box.
#
#   docker build -t lex-robot .
#   docker run --rm lex-robot                 # make smoke (check + all 4 demos)
#   docker run --rm lex-robot make demo       # just the LLM-planner demo
#
# (The ML demos — gym/mujoco/torch — are not in this image; see the README.)
FROM python:3.12-slim

ARG LEX_VERSION=v0.10.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates git make \
 && rm -rf /var/lib/apt/lists/*

# Pick the right release binary for the build architecture (amd64 / arm64).
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)        tgt=x86_64-unknown-linux-gnu ;; \
      aarch64|arm64) tgt=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/alpibrusl/lex-lang/releases/download/${LEX_VERSION}/lex-${LEX_VERSION}-${tgt}.tar.gz" -o /tmp/lex.tgz; \
    tar -xzf /tmp/lex.tgz -C /tmp; \
    mv "/tmp/lex-${LEX_VERSION}-${tgt}/lex" /usr/local/bin/lex; \
    rm -rf /tmp/lex*; \
    lex version

WORKDIR /app
COPY . .

# Pre-fetch the public lex-trail dependency into the image (also validates the
# build) so `docker run` works without a network round-trip on first use.
RUN lex check examples/llm_planner_demo.lex

CMD ["make", "smoke"]
