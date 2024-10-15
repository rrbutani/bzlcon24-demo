# syntax=docker/dockerfile:1-labs
# note: needed for `security=insecure`; see:
# https://docs.docker.com/reference/dockerfile/#run---security

# Ubuntu 24.04:
ARG BASE_IMAGE=ubuntu:noble-20240904.1
ARG BAZEL_FORK_GIT_REPO_URL=https://github.com/rrbutani/bazel.git
ARG BAZEL_FORK_TAG=sandboxing-tweaks-2024-06-03
ARG CLANG_VER=1:18.1.3-1ubuntu1

#-------------------------------------------------------------------------------

## Build the bazel fork, from source.

FROM ${BASE_IMAGE} AS bazel_build_stage1
SHELL ["/bin/bash", "-eu", "-o", "pipefail", "-c"]

# NOTE: this is not really reproducible (i.e. `apt update`) but... it's fine.
RUN <<DEPS
    apt update
    apt install -y curl git
    apt install -y unzip zip python3 gcc g++
DEPS

ARG BAZELISK_VERSION=1.22.0
RUN <<BAZELISK
    if [[ "$(arch)" == "x86_64" ]]; then arch=amd64
    else
        echo "unsupported architecture: $(arch)"
        exit 5
    fi

    url=https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/bazelisk-linux-${arch}
    curl -L "${url}" -o /bin/bazelisk
    chmod +x /bin/bazelisk
BAZELISK

WORKDIR /src

# Fetch:
ARG BAZEL_FORK_GIT_REPO_URL BAZEL_FORK_TAG
RUN git clone --depth 1 \
    --branch "${BAZEL_FORK_TAG}" "${BAZEL_FORK_GIT_REPO_URL}" .

# Build options:
RUN cat > user.bazelrc <<-OPTS
	common --incompatible_strict_action_env=true

	# Use output base on tmpfs:
	startup --output_user_root=/tmp/bazel

	# Useful for debugging/logging:
	common --announce_rc
	common --verbose_failures
	common --color=yes

	# Optimized build:
	common -c opt

	# Record timestamp:
	common --stamp

	# Use remote JDK:
	common --java_runtime_version=remotejdk_17

	# Embed version and commit hash in binary:
	common --embed_label="$(
	    # See:
	    #   - https://github.com/bazelbuild/bazel/blob/1bae565d1975b738a2c56e8b95aa3fa3e44e9c86/scripts/bootstrap/buildenv.sh#L253-L283
	    #   - https://github.com/bazelbuild/bazel/blob/00f8d65c36bab4199ca006ded2a0fa055f39f6a9/compile.sh#L49-L51
	    #   - https://github.com/bazelbuild/bazel/blob/bd63c6104951a5e1aac85ec8cc8e2d0c084390c1/scripts/bootstrap/bootstrap.sh#L27-L30
	    #
	    # NOTE: `get_last_version` has a bug? always calls `date` instead of
	    # using `git_date` (TODO(rrbutani)):
	    # https://github.com/bazelbuild/bazel/blame/788b6080f54c6ca5093526023dfd9b12b90403f8/scripts/bootstrap/buildenv.sh#L279
	    set +u +e; source scripts/bootstrap/buildenv.sh || :;
	    echo "$(get_last_version) (@$(git_sha1)-${BAZEL_FORK_TAG})"
	)"

	## Hermetic Sandbox Opts
	common:strict_sandboxing --experimental_use_hermetic_linux_sandbox
	common:strict_sandboxing --sandbox_add_mount_pair=/bin
	common:strict_sandboxing --sandbox_add_mount_pair=/lib64
	common:strict_sandboxing --sandbox_add_mount_pair=/usr
	common:strict_sandboxing --sandbox_add_mount_pair=/lib
	common:strict_sandboxing --sandbox_add_mount_pair=/etc
OPTS

# First, build using upstream bazel:
RUN <<BUILD
    bazelisk build //src:bazel
    bin=$(bazelisk cquery --output=files //src:bazel)
    cp "${bin}" /bin/bazel
BUILD

#-------------------------------------------------------------------------------

FROM bazel_build_stage1 AS bazel_build_stage2

# Next, build again using the previously built binary, this time with the
# hermetic linux sandbox enabled.
#
# This is a crude by effective way to check that the build binary works and that
# sandboxing isn't obviously broken.
#
# NOTE: `--security=insecure` is required to use the linux-sandbox within the
# build-time container. This requires passing `--allow security.insecure` to
# `docker build`.
RUN --security=insecure <<STAGE2
    bazel build --config=strict_sandboxing //src:bazel
    bin=$(bazel-stage1 cquery --output=files //src:bazel)
    cp "${bin}" /bin/bazel

    bazel --version
STAGE2

#-------------------------------------------------------------------------------

FROM ${BASE_IMAGE}
SHELL ["/bin/bash", "-eu", "-o", "pipefail", "-c"]

ARG CLANG_VER
RUN <<DEPS
    declare -a deps
    deps+=(
        git=1:2.43.0-1ubuntu7.1

        python3=3.12.3-0ubuntu2
        python3-pip=24.0+dfsg-1ubuntu1
        pax-utils=1.3.7-1 # for lddtree

        git-delta=0.16.5-5

        clang-$(echo ${CLANG_VER} | cut -d':' -f2 | cut -d. -f1)=${CLANG_VER}

        curl tree
    )
    apt update
    apt install -y "${deps[@]}"
DEPS


# In practice we would use the repo rules in `@rules_python` to handle such
# deps... this is a contrived example to demonstrate how we might handle python
# deps that aren't publicly available and are hard to manage the installation of
# via repo rules.
RUN <<PYDEPS
    declare -a pydeps
    pydeps+=(
        pyelftools==0.31
    )
    pip install --break-system-packages "${pydeps[@]}"
PYDEPS

ARG BAZEL_VER=7.3.2
RUN <<BAZEL
    curl -L https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VER}/bazel-${BAZEL_VER}-linux-x86_64 -o /bin/bazel${BAZEL_VER}
    chmod +x /bin/bazel${BAZEL_VER}
    ln -s /bin/bazel${BAZEL_VER} /bin/bazel7
    ln -s /bin/bazel7 /bin/bazel
BAZEL

# NOTE: for now, using the stage1 build instead of stage2 —
# `--allow security.insecure` requires extra daemon configuration, annoying for
# folks trying to give this a spin.
COPY --from=bazel_build_stage1 /bin/bazel /bin/bazel-fork-bin

# Pre-extract the install base, use an output base on `/tmp`:
ARG BAZEL_FORK_TAG
RUN cat >> /etc/bazel.bazelrc <<-CONFIG
	# Use output base on tmpfs:
    startup --output_user_root=/tmp/bazel
CONFIG
RUN <<WRAPPER
    {
        echo "#!/usr/bin/env bash"
        echo "exec /bin/bazel-fork-bin --install_base=/bin/bazel-install-bases/${BAZEL_FORK_TAG}" '"$@"'
    } > /bin/bazel-fork
    chmod +x /bin/bazel-fork

    ln -s /bin/bazel-fork "/bin/bazel'"
WRAPPER
RUN --mount=type=tmpfs,target=/tmp <<INSTALL_BASE
    cd "$(mktemp -d)"
    touch MODULE.bazel
    bazel-fork info
INSTALL_BASE

RUN <<EXTERNAL_ARTIFACTS
    base=/nfs/special/project/area/foo/
    ver=1.0.0

    mkdir -p /nfs/mutable_space/special
    ln -s /nfs/mutable_space/special /nfs/special
    mkdir -p /nfs/a/area
    ln -s /nfs/a/ /nfs/mutable_space/special/project
    mkdir -p ${base}${ver}/{assets,bin}
    ln -s ${ver} ${base}/latest
    mkdir -p /nfs/projects
    ln -s ${base} /nfs/projects/foo

    echo "hey there bazelcon!" > ${base}/${ver}/assets/prelude
    {
        echo "#!/usr/bin/env bash"
        echo "echo '# first 10 lines:'"
        echo "exec head"
    } > ${base}/${ver}/bin/frob
    chmod +x ${base}/${ver}/bin/frob

    chown -R ubuntu ${base}
    chmod -R a+rw ${base}
EXTERNAL_ARTIFACTS

ARG BASE_IMAGE BAZEL_FORK_GIT_REPO_URL
LABEL base_image=${BASE_IMAGE} \
      bazel.fork.url=${BAZEL_FORK_GIT_REPO_URL} \
      bazel.fork.tag=${BAZEL_FORK_TAG} \
      clang.version=${CLANG_VER}

# NOTE: change as needed; may need to create a new user so the uid/gid aligns
USER ubuntu
WORKDIR /workarea
