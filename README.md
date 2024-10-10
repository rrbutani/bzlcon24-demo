
# Extended Bazel Linux Sandbox Demo

## what

...

## how do i run this?

> [!NOTE]
> This repo demonstrates the use of the [extended Bazel linux sandbox](TODO: fork link, talk link) to describe all "host system" dependencies.
>
> In doing do we end up talking about system specific details and paths (i.e. of shared objects) — while it's possible to model these details in a system agnostic way in Bazel (i.e. by using repository rules that do auto-detection) for the sake of this example, for simplicity, we use a [Docker container](./Dockerfile) to define a common system environment.

> [!IMPORTANT]
> This repo only works with x86_64 Linux — in theory adapting what's here to other architectures (aarch64, armv7, riscv64) should be straight-forward but it has not been attempted.

> [!WARNING]
> Privileges are required (see [here](https://man7.org/linux/man-pages/man7/capabilities.7.html) and [here](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)) [^caveat] in order to use Bazel's linux sandbox within Docker (allows us to create user namespaces within an existing user namespace); at run time we pass `--privileged`, at container build time we do not use the linux sandbox.

<!-- at container build time we make use of [`--security=insecure`](https://github.com/moby/moby/issues/1916) (see [here](https://docs.docker.com/reference/dockerfile/#run---security)) + `docker buildx build --allow security.insecure` (requires [daemon configuration](https://github.com/docker/buildx/issues/559#issuecomment-796430825)). -->

```console
❯ docker build \
    ${https_proxy+--build-arg HTTPS_PROXY="$https_proxy"} \
    -t bzlcon24-demo - < Dockerfile
```

[^caveat]: unfortunately scoping down the permissions to `-cap-add=SYS_ADMIN --cap-add=CAP_SYS_CHROOT` isn't sufficient — still yields permission errors for `mount`, have not investigated..
