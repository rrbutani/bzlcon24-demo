"""Wrapper on `filegroup` for external dependencies.

This file exposes a `filegroup` wrapper that is able to pick between listing out
the files within the group (using `glob`s) and using (fuzzy) directory based
approximations.

Background: the discussion here assumes use of the [strict sandboxing options]
which enables the hermetic Bazel sandbox (does not mount in the host filesystem)
and (when used in conjunction with the Bazel fork) has the sandbox bind mount in
external paths that are needed for each action.

[strict sandboxing options]: ../README.md

---

The tradeoff here has to do with:
  - memory usage in Bazel/sandbox setup overhead
  - hermeticity and correctness
  - granuality of access

### Memory Usage and Sandbox Overhead

Having Bazel track every file in a large external dependency (i.e. a python
interpreter) consumes memory during analysis and execution (expanding the globs
for these directories presumably also has some impact on the loading phase but
we have not attempted to verify/quantify this). **This affects Bazel whether the
strict sandboxing options are used or not.**

More concerning is that when the strict sandboxing options are used, bind
mounting in all of the files from external dependencies can pose significant
overhead (see the [Python dep's build file template][py] for concrete numbers;
initial testing showed overhead up to an extra second on individual actions).
This is untenable.

This issue is not specific to the strict sandboxing strategy; upstream has this
issue as well:
  - https://github.com/bazelbuild/bazel/issues/8230#issuecomment-1886146477
  - https://github.com/tweag/rules_nixpkgs/pull/103

[py]: (TODO)

### Hermeticity and Correctness

This is particularly irksome because for external deps we often have guarantees
of immutability _anyways_ (i.e. we can be pretty confident that unwritable
directories on a shared filesystem (NFS) are not going to change out from
underneath us; in content stores like the `nix` store, paths are literally
immutable and have paths containing hashes reflecting the configuration that
produced each package); it's just wasteful for Bazel to be watching and hashing
these files.

This is one area in which we would be quite comfortable trading hermeticity for
speed.

### Granularity of Access

The obvious solution here is to simply depend on directories instead of
individual files: i.e. instead of doing `glob(["foo/**"])` we would simply list
the directory `foo` as a dependency.

This, unfortunately, has some caveats:
  - Bazel will warn you that "dependency checking of directories is unsound":
    + see: https://github.com/bazelbuild/bazel/commit/2fe450fd7f8888e619e38aa0b359073e801f1120
    + for example:
      ```
      input 'lib64' to //:perl_test is a directory; dependency checking of directories is unsound
      ```
    + source directories tracking can be enabled with the java option
      [`-DBAZEL_TRACK_SOURCE_DIRECTORIES`](https://github.com/bazelbuild/bazel/pull/15774)
      * see: https://bazel.build/contribute/codebase#artifacts
    + but it's unclear whether this option will be officially supported:
      * see this thread for discussion: https://github.com/bazelbuild/bazel/pull/15774#issuecomment-1180727555
  - while we can emulate simple `include` arguments to [`glob`] this way we
    cannot encode complex patterns or `exclude`s like this
    * consider a directory tree that looks like this as an example:
      ```
      /shared/packages/python3/3.11.1/lib/python3.11/
        ├── LICENSE.txt
        ├── __future__.py
        ├── __hello__.py
        ├── __pycache__
        ├── _aix_support.py
        ├── site-packages
        └── ... <snipped: many many .py files that we wish to keep>
      ```
      + if we wish to _exclude_ `site-packages` in the above but wish to keep
        all of the `.py` files, listing directories as dependencies does not
        help us
      + we'd be forced to list all of the (many) python files in the directory
        in other to exclude `site-packages`
    * we'd have to compromise on access granularity in order to go this route
      + i.e. for the above example, this would mean allowing access to
        `site-packages` and hoping/trusting that actions do not depend on it
      + sometimes the effect of this is reduced hermeticity but sometimes (i.e.
        if a tool dynamically searches directories) this may mean that tools
        just do not work as intended (though this would mean that the tool
        *requires* the stricter sandbox settings which could be problematic...)

[`glob`]: https://bazel.build/reference/be/functions#glob

## The Current Solution

There are really several issues we're trying to address with regards to overhead
incurred by tracking files of external dependencies precisely:
  - memory/analysis overhead from watching many files
    * probably livable though unnecessary
  - loading phase overhead from expanding globs, passing around the label list
    * dubious, not quantified
  - execution time overhead from having many sandbox bind mounts
    * only affects the strict sandboxing options
    * not tenable; devastating overhead on each action

Using dependency directories solves the latter two issues (and solves the first
issue as well if `BAZEL_TRACK_SOURCE_DIRECTORIES` is not enabled) but has the
major flaw that _excludes_ are not expressable.

Update: this has all been implemented; see:
  - https://github.com/rrbutani/bazel/commit/c58cf7da331d1264790f1dd414235e77114afd75

## Alternatives

### Sandbox Bind Mount Flags

We could use the regular sandbox bind mount manipulation machinery (i.e.
`--sandbox_add_mount_pair`, `--sandbox_block_path`) to control these dep paths
instead of hacking the extra functionality described above into Bazel. This has
many downsides though:
  - if specified in a `.bazelrc` file or similar, this wouldn't be per action,
    it'd be global; i.e. actions that don't use a python interpreter would still
    have access to one
  - if specified in a `.bazelrc` file or similar, we need to grow additional
    machinery to ensure that the options are only applied on machines where the
    paths actually exist
  - using transitions to set the flags as needed would address the above two
    issues (i.e. we could set the flag in build and would be able to lean on
    platforms and configurations) but it's not immediately apparent how we would
    do so in an ergonomic fashion
    + we'd need to propagate these paths "upwards" from toolchains/libraries,
      we'd need _dependents_ of these external deps to transition and add the
      paths to the sandbox mounts
    + we can handle the propagating upwards part with aspects
    + but it's not clear how we would then communicate that data to a transition
      (see [this experiment](https://gist.github.com/rrbutani/b897b0b7c3d2347cff190ee6b5f57937))
      or how we would realistically apply such a transition to every rule in the
      build graph (rules we control are doable but what about external rulesets?
      what about `cc_binary`?)

### Autodetect When Simpler Bind Mounts Can Be Used

Another potential approach is for us to just mount in directories instead of
individual files if we detect that the list of mounts includes all the files in
a directory (and to cache this analysis and have it be invalidated on file
creations in the directory)... unfortunately this is a lot more complicated than
just exposing some new tags.

(and we may not want to do ^ anyways because it'll still bloat memory usage
since bazel has to watch all the files)

A more generalized version of ^ (equally difficult) would be to map a list of
file mounts into a directory into either:
  - explicit mounts (when a small subset of the files are mounted)
  - a directory mount (when all the files are mounted)
  - a dir mount + a set of _unmounts_ (when all but a few files are mounted)

Ultimately though it feels dumb for us to reverse-engineer this information when
the user is effectively already expressing the list of files in these terms
using `glob`s (which we cannot access the args of since these are evaluated and
expanded during loading...).
"""

load("//utils:strings.bzl", "error")
load("//utils:type_check.bzl", "list_type_check", "type_check")
load("@bazel_skylib//lib:types.bzl", "types")

# See: https://github.com/rrbutani/bazel/commit/452e7f7613a61fc4c6f46ed29bb281134cc4c923#diff-5814eb18abead20df8e76fee7bca5a6e488d67534631a09efcf0a513c903f524R58
ALLOW_UNSOUND_DIRECTORY_SOURCES_TAG = "allow-unsound-directory-sources-in-direct-srcs"

# See: https://github.com/rrbutani/bazel/commit/c58cf7da331d1264790f1dd414235e77114afd75#diff-5814eb18abead20df8e76fee7bca5a6e488d67534631a09efcf0a513c903f524R277-R304
HARD_EXCLUDES_KEY = "hermetic-sandbox-bind-mount-hard-excludes"
SOFT_EXCLUDES_KEY = "hermetic-sandbox-bind-mount-soft-excludes"

def deps_filegroup(
    *,
    name,
    # Should be a list of directories.
    include_dirs,
    # Should be a list of paths within `include_dirs`. Includes can only have a
    # single entry if this is specified.
    hard_excludes = [],
    # Like `hard_excludes`, should be a list of paths relative to the single
    # entry in `include_dirs`.
    soft_excludes = [],

    # optional
    # args to a `glob` (dict) or just a file list (result of a glob)
    #
    # we'd like to skip expanding the `glob` if the build setting for fuzziness
    # is currently true but unfortunately we do not have any ways to do so using
    # select
    #   - select does not lazily evaluate its arguments
    #   - glob does not accept `select`s
    #
    # the only way I can come up with to defer the expansion of the glob is to
    # place it in a different package (i.e. another `BUILD` file, exported as a
    # file group). unfortunately that would limit this function to being used
    # in repository rule implementation functions.
    #
    # currently, it does not seem like `glob`s bloat loading time by much (they
    # are cached (only re-expanded when the package or the BUILD file changes)
    # and even on NFS with a large source tree I could not increase loading time
    # by more than 1/8th of a second)
    #
    # we expect that this function will only be used in infrequently modified
    # BUILD files (i.e. for external deps) anyways
    precise_files = None,

    glob = native.glob,
    filegroup = native.filegroup,
    **extra_args,
):
    list_type_check("include_dirs", include_dirs, type("")) # no Labels!
    list_type_check("hard_excludes", hard_excludes, type(""))
    list_type_check("soft_excludes", soft_excludes, type(""))

    if types.is_list(precise_files):
        list_type_check("precise_files", precise_files, type(""))
    else:
        type_check("precise_files", precise_files, [type(None), type({})])

    def check_paths(paths, name = "include directory"):
        for p in paths:
            err = lambda msg: error("Invalid {}: `{}` {}", name, p, msg)
            if "*" in p or "**" in p: err("contains globs")
            if p.startswith("/"): err("is not relative")
            if ".." in p: err("has `..`")
    check_paths(include_dirs)
    check_paths(hard_excludes, name = "hard exclude")
    check_paths(soft_excludes, name = "soft exclude")

    # check that paths *do* end with `/`; we only accept directories in
    # `include_dirs`
    for inc in include_dirs:
        if not inc.endswith("/"):
            error("""
                Please ensure include `{i}` is a directory; all items in
                `include_dirs` must be directories.
                If it is a directory, add a trailing slash (i.e. `{i}/`).
                If not, consider using `filegroup` instead of `deps_filegroup`.
            """, i = inc)

    # This is the restriction our patches pose:
    if hard_excludes != [] and len(include_dirs) != 1: error("""
        `hard_excludes` are only permitted when `include_dirs` contains exactly
        one path!
    """)
    if soft_excludes != [] and len(include_dirs) != 1: error("""
        `soft_excludes` are only permitted when `include_dirs` contains exactly
        one path!
    """)
    include_dir = None
    if (hard_excludes != []) or (soft_excludes != []):
        include_dir = include_dirs[0]
        for exclude in hard_excludes + soft_excludes:
            if not exclude.startswith(include_dir): error("""
                hard and soft excludes must specify subpaths of the include
                directory; exclude entry `{}` is not a subpath of `{}`
            """, exclude, include_dir)

    tags = extra_args.pop("tags", [])
    if "path" in extra_args:
        error("cannot specify `path` on a `deps_filegroup`")

    ## Default:
    if precise_files != None:
        # we should maybe attempt to check for equivalence?
        if types.is_list(precise_files):
            default_srcs = precise_files
        else:
            default_srcs = glob(**precise_files)
    else:
        default_srcs = glob(
            # Our contract is that `include_dirs` contains directories only
            # (with trailing slashes on each element).
            include = [
                "{}**".format(include)
                for include in include_dirs
            ],

            # We don't know if an element in `excludes` is a path or a directory
            # so we include both:
            exclude = [
                exclude
                for ex in (hard_excludes + soft_excludes)
                for exclude in [
                    "{}".format(ex),
                    ("{}**" if ex.endswith("/") else "{}/**").format(ex),
                ]
            ],
            exclude_directories = 1,
            allow_empty = True,
        )
    default = struct(srcs = default_srcs, tags = tags)

    ## Fuzzy:
    fuzzy = struct(
        # Labels cannot end with `/` so we strip the trailing `/` on the
        # directories.
        srcs = [ inc[0:-1] for inc in include_dirs ],
        tags = tags + [ALLOW_UNSOUND_DIRECTORY_SOURCES_TAG],
        path = json.encode({
            HARD_EXCLUDES_KEY: [e.removeprefix(include_dir) for e in hard_excludes],
            SOFT_EXCLUDES_KEY: [e.removeprefix(include_dir) for e in soft_excludes],
        })
    )

    # All together:
    if_fuzzy = Label("//config:external_deps_fuzzy_directories")
    return filegroup(
        name = name,
        srcs = select({
            if_fuzzy: fuzzy.srcs,
            "//conditions:default": default.srcs,
        }) + extra_args.pop("srcs", []),
        # not bothering to gate the directory dep exemption tag behind
        # configuration (tags are not configurable)
        #
        # we do gate the excludes though since Bazel will error if they're
        # present when there's more than 1 source
        tags = fuzzy.tags,
        path = select({
            if_fuzzy: fuzzy.path,
            "//conditions:default": None,
        }),
        **extra_args,
    )
