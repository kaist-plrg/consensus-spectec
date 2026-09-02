# ============================================
# SpecTrum Docker Image Build script
# ============================================

ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION} AS base

# Avoid interactive prompts during package installation
ARG DEBIAN_FRONTEND=noninteractive
ENV DEBIAN_FRONTEND=noninteractive

# Set working directory
WORKDIR /workspace

# ============================================
# Stage 1: Install system dependencies
# ============================================
RUN apt-get update && \
    apt-get install -y \
        git \
        curl \
        wget \
        build-essential \
        gcc \
        g++ \
        make \
        cmake \
        pkg-config \
        llvm-dev \
        libclang-dev \
        clang \
        llvm \
        python3 \
        python3-pip \
        python3-dev \
        libssl-dev \
        libsnappy-dev \
        libgmp-dev \
        lcov \
        git-lfs \
        apt-transport-https \
        gnupg \
        ca-certificates \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Stage 2: Install Rust (for Lighthouse)
# ============================================
# Pin nightly for reproducible coverage builds (Lighthouse uses -Z coverage-options=branch)
ARG RUST_NIGHTLY_DATE=2026-01-15
# Pin the stable toolchain to the as-built version from the published image
ARG RUST_STABLE_VERSION=1.94.1
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    . $HOME/.cargo/env && \
    rustup default ${RUST_STABLE_VERSION} && \
    rustup component add llvm-tools-preview && \
    rustup toolchain install nightly-${RUST_NIGHTLY_DATE} --component llvm-tools-preview

ENV PATH="/root/.cargo/bin:${PATH}"

# ============================================
# Stage 3: Install Go (for Prysm)
# ============================================
ARG GO_VERSION=1.25.1
RUN wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz && \
    tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz && \
    rm go${GO_VERSION}.linux-amd64.tar.gz

ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH="/go"
ENV PATH="${GOPATH}/bin:${PATH}"

# Install go-bcov for Prysm branch coverage
ARG GO_BCOV_VERSION=1.0.4
RUN go install github.com/alx99/go-bcov@v${GO_BCOV_VERSION}

# ============================================
# Stage 4: Install Java 21 (for Teku)
# ============================================
RUN apt-get update && \
    apt-get install -y openjdk-21-jdk openjdk-21-jre && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# ============================================
# Stage 6: Install Node.js 20 (for Lodestar)
# ============================================
# Pin Node to the as-built minor via the nodesource apt version string.
# If this exact version is unavailable on a future rebuild, drop the "=${NODE_VERSION}-1nodesource1" pin.
ARG NODE_VERSION=20.20.0
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs=${NODE_VERSION}-1nodesource1 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# ============================================
# Stage 7: Install Nim (for Nimbus)
# ============================================
ARG NIM_VERSION=1.6.20
RUN wget -q https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz && \
    tar -xJf nim-${NIM_VERSION}-linux_x64.tar.xz && \
    mv nim-${NIM_VERSION} /opt/nim && \
    rm nim-${NIM_VERSION}-linux_x64.tar.xz && \
    cd /opt/nim && \
    ./install.sh /opt/nim && \
    rm -rf /opt/nim/nimcache

ENV PATH="/opt/nim/bin:${PATH}"

# ============================================
# Stage 7.5: Install OCaml and opam (for Spectec)
# ============================================
RUN apt-get update && \
    apt-get install -y \
        opam \
        m4 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Initialize opam and create OCaml switch (name must match Makefile SWITCH=eth-spectec)
# The package list mirrors the (depends ...) stanza of spectec/dune-project; keep the
# two in sync.
RUN opam init --disable-sandboxing -y && \
    opam switch create eth-spectec ocaml-base-compiler.5.1.0 && \
    eval $(opam env --switch=eth-spectec) && \
    opam install -y \
        dune \
        menhir menhirLib \
        bignum \
        bls12-381 bls12-381-signature \
        core core_unix \
        digestif \
        ppx_let \
        pprint \
        linol-eio eio_main \
        yojson bisect_ppx

ENV OPAM_SWITCH_PREFIX="/root/.opam/eth-spectec"
ENV CAML_LD_LIBRARY_PATH="/root/.opam/eth-spectec/lib/stublibs:/root/.opam/default/lib/stublibs"
ENV OCAML_TOPLEVEL_PATH="/root/.opam/eth-spectec/lib/toplevel"
ENV PATH="/root/.opam/eth-spectec/bin:/root/.opam/default/bin:${PATH}"

# ============================================
# Stage 8: Clone and set up clients
# ============================================
WORKDIR /workspace/spectec-core/testing_clients

# Clone Lighthouse (v8.0.1)
RUN git clone --depth 1 --branch v8.0.1 https://github.com/sigp/lighthouse.git

# Clone Prysm (v7.0.0)
RUN git clone --depth 1 --branch v7.0.0 https://github.com/OffchainLabs/prysm.git

# Clone Teku (25.11.1)
RUN git clone --depth 1 --branch 25.11.1 https://github.com/ConsenSys/teku.git

# Clone Nimbus (v25.11.1)
RUN git clone --depth 1 --branch v25.11.1 https://github.com/status-im/nimbus-eth2.git

# Setup Lodestar (create package.json and install dependencies)
WORKDIR /workspace/spectec-core/testing_clients
ARG PNPM_VERSION=10.20.0
ARG LODESTAR_VERSION=1.36.0

# shamefully-hoist puts them where a root-level script can import them.
RUN mkdir -p lodestar && \
    cd lodestar && \
    printf '{\n  "dependencies": {\n    "@lodestar/state-transition": "%s",\n    "@lodestar/types": "%s",\n    "@lodestar/config": "%s",\n    "@lodestar/params": "%s"\n  },\n  "type": "module",\n  "pnpm": {\n    "onlyBuiltDependencies": ["bigint-buffer"]\n  }\n}\n' "${LODESTAR_VERSION}" "${LODESTAR_VERSION}" "${LODESTAR_VERSION}" "${LODESTAR_VERSION}" > package.json && \
    printf 'shamefully-hoist=true\n' > .npmrc && \
    npm install -g pnpm@${PNPM_VERSION} && \
    pnpm install

# Bootstrap the Nimbus build system, which builds its own Nim toolchain and
# vendor tree before the ncli build below can run.
WORKDIR /workspace/spectec-core/testing_clients/nimbus-eth2
RUN JOBS=4 && \
    make -j${JOBS} deps || make -j2 deps || make deps

# ============================================
# Stage 9: Copy project files and install Python dependencies
# ============================================
COPY . /workspace/spectec-core
WORKDIR /workspace/spectec-core

# Initialize git submodules (consensus-specs)
RUN git submodule update --init --depth 1 consensus-specs

# Configure sparse-checkout for consensus-specs (required for eth2spec)
WORKDIR /workspace/spectec-core/consensus-specs
RUN git sparse-checkout init --cone && \
    git sparse-checkout set tests/core/pyspec specs configs presets pysetup sync

# Install uv (Python package manager for eth2spec)
# uv install script may install to ~/.cargo/bin (already in PATH from Rust) or ~/.local/bin
WORKDIR /workspace/spectec-core
ARG UV_VERSION=0.11.2
RUN curl -LsSf https://astral.sh/uv/${UV_VERSION}/install.sh | sh

# Add /root/.local/bin to PATH (uv may install here if not in .cargo/bin)
# Note: /root/.cargo/bin is already in PATH from Rust installation (line 57)
ENV PATH="/root/.local/bin:${PATH}"

# Build Python specification files (mainnet.py, minimal.py)
# Note: make _pyspec automatically runs uv sync first (see Makefile _pyspec: _sync dependency)
WORKDIR /workspace/spectec-core/consensus-specs
RUN make _pyspec

# Install Python dependencies (including snappy for decompression)
WORKDIR /workspace/spectec-core
RUN pip3 install --no-cache-dir -r requirements.txt

# Build spectec-core executable
WORKDIR /workspace/spectec-core
RUN eval $(opam env) && \
    make exe

# Stage 10: Apply modified code
# ============================================
WORKDIR /workspace/spectec-core

# Apply Lighthouse modifications
RUN cp modified_code/lighthouse/epoch_processing.rs \
       modified_code/lighthouse/operation.rs \
       modified_code/lighthouse/sanity_slots.rs \
       testing_clients/lighthouse/lcli/src/ && \
    for p in /workspace/spectec-core/patches/lighthouse/*.patch; do \
        git -C testing_clients/lighthouse apply --3way "$p" || exit 1; \
    done

# Apply Prysm modifications
RUN cp modified_code/prysm/pcli_spectest.go testing_clients/prysm/tools/pcli/ && \
    for p in /workspace/spectec-core/patches/prysm/*.patch; do \
        git -C testing_clients/prysm apply --3way "$p" || exit 1; \
    done

# Apply Teku modifications
RUN for p in /workspace/spectec-core/patches/teku/*.patch; do \
        git -C testing_clients/teku apply --3way "$p" || exit 1; \
    done

# Apply Nimbus modifications
WORKDIR /workspace/spectec-core
RUN for p in /workspace/spectec-core/patches/nimbus/*.patch; do \
        git -C testing_clients/nimbus-eth2 apply --3way "$p" || exit 1; \
    done

# Apply Lodestar modifications
RUN cp modified_code/lodestar/transition.js \
       modified_code/lodestar/generateCachedStateCapella.js \
       testing_clients/lodestar/

# Comment out postState.commit() calls in Lodestar node_modules
RUN f=testing_clients/lodestar/node_modules/@lodestar/state-transition/lib/stateTransition.js && \
    n=$(grep -c '^[[:space:]]*postState\.commit();' "$f") && \
    if [ "$n" -ne 3 ]; then echo "expected 3 postState.commit() calls, found $n" >&2; exit 1; fi && \
    sed -i 's/^\([[:space:]]*\)postState\.commit();/\1\/\/postState.commit();/' "$f"

# ============================================
# Stage 11: Build original clients (no coverage)
# ============================================
WORKDIR /workspace/spectec-core/testing_clients

# Build Lighthouse
WORKDIR /workspace/spectec-core/testing_clients/lighthouse
RUN cargo build --release --bin lcli

# Build Prysm
WORKDIR /workspace/spectec-core/testing_clients/prysm
RUN go build -o pcli ./tools/pcli

# Build Teku
WORKDIR /workspace/spectec-core/testing_clients/teku
RUN ./gradlew installDist

# Build Nimbus
WORKDIR /workspace/spectec-core/testing_clients/nimbus-eth2
RUN if [ -f "./env.sh" ]; then \
        ./env.sh nim c -d:const_preset=mainnet -o:ncli/ncli ncli/ncli.nim; \
    else \
        nim c -d:const_preset=mainnet -o:ncli/ncli ncli/ncli.nim; \
    fi

# Verify Lodestar (no build needed)
WORKDIR /workspace/spectec-core/testing_clients/lodestar
RUN test -f transition.js || test -f transition || echo "Warning: Lodestar transition.js not found"

# ============================================
# Stage 12: Coverage build stage
# ============================================
# Note: This stage inherits from base, so spectec-core executable,
# consensus-specs (eth2spec), and all other dependencies are already available.
FROM base AS coverage

WORKDIR /workspace/spectec-core

# Build Lighthouse with coverage (use same pinned nightly as Stage 2)
ARG RUST_NIGHTLY_DATE=2026-01-15
WORKDIR /workspace/spectec-core/testing_clients/lighthouse
RUN RUSTFLAGS="-Cinstrument-coverage -Z coverage-options=branch" \
    cargo +nightly-${RUST_NIGHTLY_DATE} build --release --bin lcli && \
    cp target/release/lcli target/release/lcli-cov

# Build Prysm with coverage
WORKDIR /workspace/spectec-core/testing_clients/prysm
RUN go build -cover -o pcli-cov ./tools/pcli

# Build Teku with coverage (download JaCoCo agent)
WORKDIR /workspace/spectec-core/testing_clients/teku
RUN ./gradlew installDist && \
    cp -r build/install/teku build/install/teku-cov

# Download JaCoCo agent to the expected location (matching build_coverage_clients.sh)
WORKDIR /workspace/spectec-core/testing_clients
RUN mkdir -p jacoco && \
    wget -q -O jacoco/jacocoagent.jar https://repo1.maven.org/maven2/org/jacoco/org.jacoco.agent/0.8.11/org.jacoco.agent-0.8.11-runtime.jar && \
    wget -q -O jacoco/jacococli.jar https://repo1.maven.org/maven2/org/jacoco/org.jacoco.cli/0.8.11/org.jacoco.cli-0.8.11-nodeps.jar

# Build Nimbus with coverage
WORKDIR /workspace/spectec-core/testing_clients/nimbus-eth2
RUN if [ -f "./env.sh" ]; then \
        ./env.sh nim c -d:const_preset=mainnet \
            --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs \
            -o:ncli/ncli-cov ncli/ncli.nim; \
    else \
        nim c -d:const_preset=mainnet \
            --passC:-fprofile-arcs --passC:-ftest-coverage --passL:-fprofile-arcs \
            -o:ncli/ncli-cov ncli/ncli.nim; \
    fi

# Verify Lodestar c8 availability
WORKDIR /workspace/spectec-core/testing_clients/lodestar
ARG C8_VERSION=11.0.0
RUN npx --yes c8@${C8_VERSION} --version || echo "c8 will be installed on first use"

# ============================================
# Final stage: Set working directory
# ============================================
WORKDIR /workspace/spectec-core

# Default command
CMD ["/bin/bash"]
