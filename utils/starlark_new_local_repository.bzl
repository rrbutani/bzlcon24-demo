
"""Starlark version of `new_local_repository` for module extensions.

Currently `native.new_local_repository` cannot be called from Bazel module
extensions: https://github.com/bazelbuild/bazel/issues/15412

The plan is to eventually "starlark-ify" this rule:
  - https://docs.google.com/document/d/17RZKMuMjAIgNfFdrsLhqNsMTQDSS-BBA-S-fCSBPV7M/edit
  - https://github.com/bazelbuild/bazel/issues/18285

In the interim we've got our own Starlark-native `new_local_repository`
lookalike with one major caveat:
  - As mentioned in the issue and the design doc linked above,
    `new_local_repository` is "special" because it registers a dependency on
    the directory of the `new_local_repository`; changes to the directory will
    cause the **repository rule** to be re-run (thus picking up, i.e. newly
    created/deleted files, new dirs, etc.).
  - As outlined in the design doc, we have no ability to watch directories from
    repository rules we write today so we cannot arrange for this repository
    rule to be re-run when things within the directory change.
  - So, this rule asks for an explicit list of top-level symlinks to create
    within the repository. This still is not perfect (i.e. deleting files within
    the directory `path` points to that we have made symlinks to will not cause
    the repo rule to be re-run; instead you'll just get errors about broken
    symlinks at "runtime") but afaik there aren't correctness issues.
  - Note: the "missing" dependency on the dir pointed to by `path` only affects
    the repository rule itself; targets that depend on files within the
    repository created by this rule will still have real content-based
    dependencies on the files.
"""

load(":strings.bzl", "dedent", "error", C = "colors")
load("@bazel_skylib//lib:paths.bzl", "paths")

def make_new_local_repository_symlinks(
    rctx,
    dir_path,
    top_level_symlinks,
    error_on_missing_src = True,
):
    """Repo rule helper function for creating symlinks to a local directory.

    Args:
      rctx: [repository context] object.
      dir_path: Directory path (as a string) that the symlinks will point into.
      top_level_symlinks: List of relative paths (as strings) into `dir_path`.

        These determine what items in `dir_path` are to be symlinked into the
        new repository.
      error_on_missing_src: If true errors on non-existent symlink source paths.

        Set to `False` to allow `top_level_symlinks` to contain relative paths
        that do not exist in `dir_path` (and/or `dir_path`s that do not exist)
        on the host machine's local filesystem.

    [repository_context]: https://bazel.build/rules/lib/builtins/repository_ctx
    """

    # If `dir_path` is not absolute make it relative to `rctx.workspace_root`:
    if not paths.is_absolute(dir_path):
        dir_path = rctx.workspace_root.get_child(dir_path)

    dir_path = rctx.path(dir_path)

    # Create the symlinks:
    rctx.report_progress("Creating {} symlinks from `{}`".format(
        len(top_level_symlinks), dir_path
    ))
    for link in top_level_symlinks:
        if link == "": error("""
            {RED}Top level symlink cannot be `""`.{R}
            {newl}
            {newl}Creating this symlink would cause us to make the entire
            repository a symlink to `path` ({B}{dir_path}{R})
            {newl}which means the generated BUILD and WORKSPACE files would be
            written into `path`.
            {newl}
            {newl}(i.e. we'd be making modifications outside of the Bazel
            execroot).
        """, span_ctx = rctx, newl = "\n", B = C.BOLD, RED = C.RED, R = C.RESET,
            dir_path = dir_path,
        )

        src = dir_path.get_child(link)

        if error_on_missing_src and not src.exists:
            error("""
                Requested path `{link}` under `{dir}` but `{src}` doesn't exist.
            """, span_ctx = rctx, link = link, dir = dir_path, src = src)

        # Note: `rctx.symlink(..., link)` ensures that `link` is relative and
        # does not escape its parent directory.
        rctx.symlink(src, link)

def _new_local_repository_impl(rctx):
    # Make symlinks:
    make_new_local_repository_symlinks(
        rctx,
        rctx.attr.path,
        rctx.attr.top_level_symlinks,
        rctx.attr.error_on_missing_src,
    )

    # Create `BUILD.bazel`:
    e = error
    if rctx.attr.build_file_content == "" and rctx.attr.build_file == None: e(
        "Must specify `build_file_content` or `build_file`; neither are set."
    )
    elif rctx.attr.build_file_content != "" and rctx.attr.build_file != None: e(
        "Must specify `build_file_content` or `build_file`; both were provided."
    )

    build_file_content = rctx.attr.build_file_content
    if rctx.attr.build_file != None:
        # We make a copy instead of a symlink.
        #
        # Declare a dependency on this label by doing `rctx.path(Label(...))`:
        build_file = rctx.path(Label(rctx.attr.build_file))
        build_file_content = rctx.read(build_file)

    rctx.file("BUILD.bazel", content = build_file_content, executable = False)


new_local_repository = repository_rule(
    implementation = _new_local_repository_impl,
    attrs = {
        "build_file_content": attr.string(
            default = "",
            doc = dedent("""
                String to use as the contents of `BUILD.bazel` for the top-level
                for the generated repository.

                Exactly one of this or `build_file` must be specified; not both.
            """),
        ),
        "build_file": attr.label(
            allow_single_file = True,
            doc = dedent("""
                Label to a file to use as `BUILD.bazel` for the top-level of
                the generated repository.

                Exactly one of this or `build_file_content` must be specified;
                not both.
            """),
        ),
        "path": attr.string(
            mandatory = True,
            doc = dedent("""
                Path on the local filesystem.

                If this is a relative path, it is prefixed with the path to the
                main workspace.
            """),
        ),
        # TODO(build, bazel, 7.1.0, lo-prio): can use `path.readdir(watch)` to
        # obviate the need for this; perhaps have an empty list imply ^?
        "top_level_symlinks": attr.string_list(
            allow_empty = True,
            mandatory = True,
            doc = dedent("""
                Paths under `path` to create symlinks for within the top-level
                of the generated repository.

                The expectation is that these paths are relative (not absolute)
                and do not escape the directory `path` points to.
            """),
        ),
        "error_on_missing_src": attr.bool(
            default = True,
            doc = dedent("""
                If `True` errors if paths in `top_level_symlinks` do not exist
                on the local filesystem.

                Under most circumstances this is what you want however when
                configuring a repo for use with RBE (i.e. setting up a
                `new_local_repository` for paths that exist on remote builder
                machines but do not exist on the host), eliding this check can
                be useful (TODO: verify that this actually works?).
            """),
        ),
    },
    # Rerun on every fetch to pick up changes (i.e. broken symlinks) early.
    #
    # This rule should be cheap to run so we've not concerned about the extra
    # work.
    local = True,
    # No need to gate this rule behind `bazel sync --configure`.
    configure = False,
    # No env var deps.
    environ = [],
    # Users that wish to use this rule to set up repos for RBE should do so by
    # setting `error_on_missing_src` to `False` (or by invoking the
    # `make_new_local_repository_symlinks` helper from within their own
    # repository rule).
    remotable = False,
    doc = dedent("""
        Starlark version of `new_local_repository` for module extensions.

        See the docs at `@//build/bazel/utils:starlark_new_local_repository.bzl`
        for more details.
    """),
)
