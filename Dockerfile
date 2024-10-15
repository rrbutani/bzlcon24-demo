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

COPY --from=bazel_build /bin/bazel /bin/bazel

RUN <<BLOCK

BLOCK

ARG BASE_IMAGE BAZEL_FORK_GIT_REPO_URL BAZEL_FORK_TAG
LABEL base_image=${BASE_IMAGE} \
      bazel.fork.url=${BAZEL_FORK_GIT_REPO_URL} \
      bazel.fork.tag=${BAZEL_FORK_TAG}

# TODO: mounts?

# TODO: /etc/bazelrc
#   - install base
#   - tmp user output root
