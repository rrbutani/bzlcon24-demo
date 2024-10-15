#!/usr/bin/env nix-shell
#! nix-shell -i python3.11 -p python311 python311Packages.pyelftools pax-utils delta

"""
Generates a `.bzl` file that creates a Bazel repository describing the specified
host binaries and their shared object dependencies.

Note that we do not invoke this script as part of a repo rule in Bazel though
we _could_; the idea is that the description of the parts of the host system
that we depend upon shouldn't change often and should not change without us
noticing. This script exists because writing this description is tedious.
However, we should be auditing what this file emits.

## Usage

(you can run this without `nix` if you run the Bazel target (Bazel provides the
necessary deps))
"""

import argparse
from collections import UserDict
from dataclasses import dataclass
import functools
import os.path
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import NamedTemporaryFile
from typing import Dict, Iterable, List, Optional, Self, Set, Tuple

# External imports
try:
    # When run under Bazel this is sufficient.
    import lddtree
except ImportError as e:
    # If we're running outside of Bazel (i.e. where the python library for
    # `pax-utils` isn't on the python path), we can find the path to `lddtree`
    # on `$PATH`.
    #
    # Note: this file doesn't end with `.py` so we can't just add it's parent
    # dir to the Python PATH.
    #
    # Note that we already depend on `lddtree`'s only dep (pyelftools) so this
    # is sufficient; we don't have to also go and parse
    # `nix-support/propagated-inputs` or go and use the python wrapper that
    # `pax-utils`' `python3.withPackages (p: [...])` produces.
    if path := shutil.which("lddtree"):
        # Little bit of goop to import from a file not ending in `.py` wihout
        # using the (soon-to-be deprecated) `imp` module.
        #
        # Loosely based on: https://stackoverflow.com/a/73928473
        import importlib.util, importlib.machinery
        file = importlib.machinery.SourceFileLoader("lddtree", path)
        spec = importlib.util.spec_from_loader("lddtree", file)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        sys.modules["lddtree"] = module
        import lddtree
    else:
        raise Exception(f"unable to import `lddtree` ({e}) and unable to find `lddtree` on `$PATH`!")

from lddtree import ParseELF, LoadLdpaths
from elftools.elf.elffile import ELFFile
from elftools.elf.descriptions import describe_e_type

parser = argparse.ArgumentParser(usage = (
    "Generate a .bzl file, detailing host binaries and their shared " +
    "object dependencies."
))
parser.add_argument(
    'host_binaries', nargs = '+',
    help = "list of host binaries to include in the generated repository",
)
parser.add_argument(
    '--extra-binary', default = [], action = 'append',
    help = (
        "binaries to include in the generated repository but to *not* include "
        + "in the generated list of binaries "
        + "-- "
        + "subsequent regenerates will not automatically include this binary "
        + "unless its addition is arranged somehow (i.e. `EXTRA_BINARIES`, "
        + "command line argument)"
    ),
)
parser.add_argument(
    '--fuzzy-dep-path', default = [], action = 'append',
    help = (
        "paths to symlinks that, when encountered, are not resolved further "
        + "-- "
        + "this can be used to paper over discrepancies between exact shared "
        + "object versions on machines"
    ),
)
parser.add_argument(
    '-n', "--repo-name", default = "host_deps",
    help = "name of the repository the .bzl file should create",
)
parser.add_argument(
    '-r', "--path-to-main-repo", default = None,
    help = (
        "path to the root of the main repository; this is where we'll put the "
        + "generated .bzl file -- if None this will be inferred from the path "
        + "to this script (presumed to live in the main repo)"
    )
)
parser.add_argument(
    '-p', "--package", default = "",
    help = "package in the specified repository to emit the generated .bzl file to",
)
parser.add_argument(
    '-f', "--file-path", default = "host_deps_info.bzl",
    help = "path of the .bzl file to generate under `package`",
)
parser.add_argument(
    "--package-within-main-repo-for-script", default = "deps/host_libs",
    help = "package within the main repo where this file resides",
)
parser.add_argument(
    "--file-path-within-package-for-script", default = "update_shared_libs.py",
    help = "path to this script within the package it lives in",
)
parser.add_argument(
    "--target-name-within-package-for-script", default = "update_shared_libs",
    help = "target name for this script within the package it lives in",
)
parser.add_argument(
    '-e', '--emit-on-stdout', default = False, action = argparse.BooleanOptionalAction,
    help = "dump the generated .bzl file to stdout instead of replacing the file"
)
parser.add_argument(
    '-d', "--show-diff", default = False, action = argparse.BooleanOptionalAction,
    help = "display what has changed between the existing copy of the .bzl file and what this script generated",
)

BOLD = "\u001b[1m"
BLUE = "\u001b[34m"
YELLOW = "\u001b[33m"
RED = "\u001b[31m"
GREEN = "\u001b[32m"
RESET = "\u001b[0m"

def info(*a, level = 0, **kw): print(" " * 6 * level + GREEN + "info" + RESET + ":", *a, **kw, file = sys.stderr)
def warn(*a, level = 0, **kw): print(" " * 6 * level + BOLD + YELLOW + "warn" + RESET + ":", *a, **kw, file = sys.stderr)
def crit(*a, level = 0, **kw): print(" " * 6 * level + BOLD + RED + "crit" + RESET + ":", *a, **kw, file = sys.stderr)

@functools.cache
def find_lddtree() -> Path:
    if res := shutil.which("lddtree"):
        return Path(res)
    else:
        raise Exception("unable to find `lddtree` on `$PATH`!")

@dataclass
class DynamicExecutable:
    path: Path
    deps: List[Tuple[str, Path, Path]] # (shortname, path -- *not* realpath, realpath)

    def add_dep(self, shortname: str, path: Path, dep: 'SharedObject'):
        self.deps.append((shortname, path, dep.path))

@dataclass
class SharedObject(DynamicExecutable):
    aliases: Set[Path] # symlinks that point to this shared object

    # in this class `.path` is the realpath (unless fuzziness was requested)
    is_fuzzy: bool = False # i.e. did we keep from resolving a symlink because fuzziness was requested

    # path here may be a symlink; we'll resolve it to a realpath (and record all
    # the symlinks we encounter on the way) while respecting `fuzzy_dep_paths`
    def __init__(
        self,
        path: Path | str,
        deps: List[Tuple[str, Path, Path]] = None,
        name = "unknown",
        fuzzy_dep_paths: Dict[Path, bool] = {},
    ):
        if isinstance(path, str): path = Path(path)
        if path == None: raise ValueError(f"got {path} as path for {name}")
        orig_path = path

        # defaults are "early bound"; we don't want instances of SharedObject to
        # share the same list instance for `deps`
        if deps is None: deps = []

        assert path.exists(), f"{path} (for shared object {name}) does not exist!"
        aliases = []

        self.is_fuzzy = False
        while path.is_symlink():
            if path in fuzzy_dep_paths:
                fuzzy_dep_paths[path] = True
                info(f"`{path}` is in the fuzzy dep path list; not following further", level = 1)
                self.is_fuzzy = True
                break

            aliases.append(path)
            link = path.readlink()
            if link.is_absolute():
                path = link
            else:
                path = Path(os.path.normpath(os.path.join(path.parent, link)))

        if not self.is_fuzzy and (exp := orig_path.resolve()) != path:
            space = "\n" + " " * 12 # for level 1 + indent
            warn(
                f"expected: `{exp}`",
                space + f"     got: `{path}`",
                space + f"have aliases: `{aliases}`...",
                "\n" + space + "there's likely a symlink within the path (should be okay)",
                level = 1,
            )

        self.path = path
        self.aliases = set(aliases)
        self.deps = deps

    def basename(self) -> str: return self.path.name

    def merge(self, other: Self) -> Self:
        assert (
            self.path == other.path and
            self.deps == other.deps and
            self.is_fuzzy == other.is_fuzzy
        ), f"cannot merge; this: {self}, that: {other}"

        res = SharedObject.__new__(SharedObject)
        res.path = self.path
        res.deps = self.deps
        res.aliases = self.aliases.union(other.aliases)
        res.is_fuzzy = self.is_fuzzy

        return res

@dataclass
class Binary(DynamicExecutable): pass

class SharedObjectStore(UserDict[Path, SharedObject]):
    def __setitem__(self, key: Path, item: SharedObject) -> None:
        if key in self.data:
            item = self.data[key].merge(item)
        return super().__setitem__(key, item)

    def add(self, item: SharedObject): self.__setitem__(item.path, item)

    def __str__(self) -> str:
        out = []
        p = lambda i: out.append(i)

        for path, so in self.data.items():
            p(f"{str(path)} => {{")
            assert path == so.path

            if so.aliases:
                p(f"  aka:")
                for alias in so.aliases:
                    p(f"    → {alias}")

            if so.deps:
                p(f"  deps:")
                for shortname, _path, abs_path in so.deps:
                    p(f"    → {shortname:30} at {str(abs_path):>40}")

            p("}\n")

        return "\n".join(out)

# NOTE: unused; obviated by `process_file`
def run_lddtree(path: Path | str, store: SharedObjectStore) -> Binary:
    info(f"processing binary `{str(path)}`")
    try:
        p = subprocess.run(
            [find_lddtree(), "--all", path],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as ex:
        err = ex.stderr.decode("utf-8")
        print(f"Error when invoking `lddtree`: {err}", file = sys.stderr)
        raise ex

    first, *deps = p.stdout.decode("utf-8").splitlines()

    # assuming the interpreter depends on nothing
    bin_path, interpreter_path = first.split(" (interpreter => ")
    interpreter_path = Path(interpreter_path[:-1])
    assert bin_path == path

    # walk through the dep tree:
    stack = [Binary(Path(bin_path), [])]
    interpreter = (
        # in case a shared object is passed in, instead of a binary (i.e. there
        # won't be an interpreter path; lddtree prints `None`)
        [(1, interpreter_path.name, interpreter_path)]
        if not str(interpreter_path) == "None" #
        else []
    )
    deps = [(d.count("    "), *d.lstrip().split(" => ")) for d in deps]

    for indent_level, shortname, so_path in interpreter + deps:
        if indent_level > (depth := len(stack)):
            assert False, f"can't skip indent levels: {depth} -> {indent_level}"

        # Note: we defer adding to `store` until we've popped the shared object
        # so that it has all its deps before its added to the store.
        #
        # This is important for the merging logic to work (we assert that the
        # list of deps is the same...)
        while len(stack) > indent_level: store.add(stack.pop())

        so = SharedObject(so_path, name = shortname)
        stack[-1].add_dep(shortname, so_path, so)
        stack.append(so)

    # Add any remaining shared objects to the store:
    binary, *remaining = stack
    for so in remaining: store.add(so)

    return binary

LDDTREE_DEBUG = False # make configurable?

system_ld_paths = LoadLdpaths()
def process_file(
    path: Path | str,
    store: SharedObjectStore,
    fuzzy: Dict[Path, bool],
) -> DynamicExecutable:
    path = Path(path)
    info(f"processing file at `{str(path)}`")

    # For inputs that are shared objects (and just don't — usually — have an
    # interpreter set), `lddtree` will not be able to add the ld path search
    # dirs that are derived from the loader.
    #
    # i.e. `/lib64` and `/usr/lib64` for a loader path of `/lib64/ld.so`
    #
    # See here for more context:
    # https://github.com/gentoo/pax-utils/blob/1ddedd87363c65d6b910fe32da0f1764ba1329a9/lddtree.py#L496-L515
    #
    # This is problematic for us because `/lib64` and `/usr/lib64` are where
    # most shared objects live!
    #
    # So, if we're given a shared object that doesn't have an interpreter set,
    # we grab the ld paths that the default interpreter would confer onto the
    # ELF and add those to the paths returned.
    #
    # NOTE: `ParseELF` copies `ldpaths` so the `functools.cache` decorator is
    # safe here.
    @functools.cache
    def get_ld_paths(
        inject_ld_paths_from_default_interpreter: bool = False,
    ) -> Dict[str, List[str]]:
        if not inject_ld_paths_from_default_interpreter: return system_ld_paths

        # Unfortunately `lddtree` does not expose the interpeter-derived ld
        # paths to us directly so... we do something ikcy (monkey patch `dbg` to
        # grab the log statement that is given `ldpaths[interp]`).
        ld_interp_paths = []
        old_debug = lddtree.dbg
        lddtree.dbg = lambda _enable, *a, **_kw: (
            ld_interp_paths.append(a[1]) if len(a) != 0 and "ldpaths[interp]" in a[0]
            else None
        )

        # To guess at the "default interpreter" we just... ask for the ld paths
        # that `/usr/bin/env` would get.
        #
        # This makes several assumptions:
        #   - `/usr/bin/env` exists (a relatively sound assumption)
        #   - `/usr/bin/env` is dynamically linked (less sound...)
        #   - `/usr/bin/env` uses the same interpreter as most "regular"
        #     programs on the system (sound)
        ParseELF(path = "/usr/bin/env", ldpaths = system_ld_paths)
        lddtree.dbg = old_debug

        if len(ld_interp_paths) != 1: raise ValueError(
            f"didn't get interpreter ld paths for `/usr/bin/env` {ld_interp_paths}"
        )

        out = system_ld_paths.copy()
        out["interp"] = ld_interp_paths[0]

        return out

    needs_extra_ld_paths = False
    is_shared_object = False
    with open(path, 'rb') as file:
        elf = ELFFile(file)
        elf_type = elf['e_type']

        if elf_type == "ET_DYN":
            is_shared_object = True
            has_interp = any(elf.iter_segments(type = 'PT_INTERP'))
            needs_extra_ld_paths = not has_interp
        elif elf_type == "ET_EXEC": needs_extra_ld_paths = False
        else:  ValueError(
            "Expected a binary (ET_EXEC) or a shared object (ET_DYN) but got a different ELF type for `{}`: {}".format(
                path, describe_e_type(elf['e_type'], elf),
            )
        )

    elf_info = ParseELF(
        path = path.resolve(),
        ldpaths = get_ld_paths(needs_extra_ld_paths),
        display = path,
        debug = LDDTREE_DEBUG,
    )

    # Two passes: map lib deps into `SharedObject` instances, then fill in their
    # deps.
    assert elf_info["path"] == path
    bin = Binary(path, [])
    lib_dep_map = elf_info["libs"]

    # Add `interp` as a library dep, if present:
    interp = {}
    if (interp_path := elf_info["interp"]) != None: interp = {
        (short_name := Path(interp_path).name): SharedObject(
            interp_path, name = short_name, fuzzy_dep_paths = fuzzy,
        )
    }

    # Filter out libraries that could not be resolved; warn on them:
    skip = []
    for lib, lib_info in lib_dep_map.items():
        if lib_info["path"] == None:
            crit(f"unable to resolve a path for library {BLUE}{lib}{RESET}; skipping! info: {lib_info}", level = 1)
            skip.append(lib)

    libs = {
        lib_name: SharedObject(
            lib_info["path"], name = lib_name, fuzzy_dep_paths = fuzzy,
        )
        for lib_name, lib_info in lib_dep_map.items()
        if lib_name not in skip
    } | interp

    # Now, deps (for shared objects and the binary):
    def add_deps(to: DynamicExecutable, dep_list: List[str]):
        for dep_name in dep_list:
            if dep_name in skip: continue
            to.add_dep(
                shortname = dep_name, path = lib_dep_map[dep_name]["path"],
                dep = libs[dep_name]
            )

    for lib, so in libs.items(): add_deps(so, lib_dep_map[lib]["needed"])
    add_deps(bin, elf_info["needed"] + list(l for l in interp.keys() if l not in elf_info["needed"]))

    # Finally, add the shared objects to the store:
    #
    # (see the note in `run_lddtree` about this being intentionally deferred
    # until all the deps are registered so that the merging logic works)
    for lib in libs.values(): store.add(lib)

    return bin

# Loosely mimics the output of `lddtree`; for debugging.
def tree(
    root: DynamicExecutable,
    store: SharedObjectStore,
    indent_level = 0,
    shortname = None,
    path = None,
):
    p = lambda o: print(o, end = "")
    p("    " * indent_level)
    if not indent_level == 0: p("")

    if shortname: p(f"{shortname} => ")
    if path:
        p(path)
        if path != root.path: p(f" ({root.path})")
    else:
        p(root.path)
    p("\n")

    for (shortname, path, realpath) in root.deps:
        tree(store[realpath], store, indent_level + 1, shortname, path)

def check_for_collisions(bins: Dict[str, Binary], store: SharedObjectStore):
    # Ensure there are no collisions:
    flattened_paths: Dict[Path, DynamicExecutable] = {}
    def put(dict: Dict[Path, DynamicExecutable], src: DynamicExecutable, path: Path):
        if path in dict:
            other = dict[path]
            raise ValueError(f"`{path}` from `{src}` collides with item at `{other.path}` (from {other})")
        else:
            dict[path] = src

    for bin_path, bin in bins.items(): put(flattened_paths, bin, bin_path)

    for so_path, so in store.items():
        for p in [so_path] + list(so.aliases):
            put(flattened_paths, so, p)

# Yields ["lib64__libc.so.6.2", "libc.so.6.2", "libc.so.6", "libc.so", "libc"]
# for `/lib64/libc.so.6.2`
def potential_labels(p: Path) -> Iterable[str]:
    yield "__".join(filter(lambda p: p != "/", p.parts))

    curr = p.name
    while (s := Path(curr).stem) != curr:
        yield curr
        curr = s
    yield curr

Potentials = List[str]
def assign_labels(bins: Dict[str, Binary], store: SharedObjectStore) -> Dict[str, DynamicExecutable]:
    out = {}

    def put(dict: Dict[str, DynamicExecutable], new: DynamicExecutable):
        get_potential = lambda p: list(potential_labels(p))[::-1]
        potentials: Potentials = get_potential(new.path)

        # As we try to place `new` in the dict, we may collide with other
        # entries; these entries are _displaced_.
        #
        # We'll use progressively longer labels for `new` and all the displaced
        # entries until we find a mapping that has a unique label for all the
        # entries.
        #
        # Note that if we end up using the absolute path fallback label for any
        # of the displaced entries we will do so for _all_ the displaced
        # entries; it would be confusing for there to be labels like
        # `:libc.so.6` and `:lib64__libc.so` instead of `:usr__lib__libc.so.6.2`
        # and `lib64__libc.so`.
        displaced: List[Tuple[DynamicExecutable, Potentials]] = [
            (new, potentials)
        ]
        level: int
        for i, _ in enumerate(potentials):
            use_last_for_all = any(map(lambda pair: i >= len(pots := pair[1]) - 1, displaced))
            if use_last_for_all: i = -1

            mapping = set(pots[i] for _, pots in displaced)
            mapping_is_unique = (len(displaced)) == len(mapping)
            mapping_has_no_overlap = all(map(lambda p: p not in dict, mapping))

            if mapping_is_unique and mapping_has_no_overlap:
                # all is well, we can use this level of labels
                level = i
                break
            else:
                # displace anything up to and including the current level and
                # then try again:
                for _, pots in displaced:
                    # note: we do the full sweep every time because
                    # `use_last_for_all` means that we can "jump" over elements
                    for label in pots[0:i] + [pots[i]]:
                        if label in dict:
                            entry = dict[label]
                            del dict[label]
                            displaced.append((entry, get_potential(entry.path)))
        else:
            # unable to find valid mapping!
            raise ValueError(f"unable to find valid mapping for: {displaced}")

        # place the entries:
        for entry, pots in displaced:
            label = pots[level]
            assert label not in dict
            dict[label] = entry

    # Binaries go first:
    for bin in bins.values(): put(out, bin)
    for so in store.values(): put(out, so)

    return out

# Optional, you don't have to use this (can just invoke `create_symlinks` from
# your own repo rule).
REPO_RULE = r"""
_BUILD_FILE = '''
load("//:info.bzl", "define_targets")
load("@rules_sh//sh:sh.bzl", "sh_binaries")

package(
    default_visibility = ["//visibility:public"],
)

EXTRA_ATTRS = dict()
{EXTRA_ATTRS_UPDATES}

define_targets(filegroup, sh_binaries, EXTRA_ATTRS)

exports_files(["info.bzl"])
'''

def _repo_impl(rctx):
    create_symlinks(rctx)

    extra_attrs_updates = [
        "EXTRA_ATTRS.update({k} = json.decode('{v}'))".format(k = k, v = v)
        for k, v in rctx.attr.extra_attrs_for_targets_as_json.items()
    ]
    rctx.file("BUILD.bazel", executable = False, content = _BUILD_FILE.format(
        EXTRA_ATTRS_UPDATES = "\n".join(extra_attrs_updates)
    ))

# This must be at the top-level or else Bazel crashes; see:
# https://github.com/bazelbuild/bazel/issues/16301
host_deps_repo = repository_rule(
    implementation = _repo_impl,
    environ = [],
    attrs = {
        "extra_attrs_for_targets_as_json": attr.string_dict(),
    },
    # Not sensitive to local system changes.
    local = False,
    configure = True,
    # Intended to operate on the host system, not an RBE machine.
    remotable = False,
)
def make_repo(extra_attrs = {}): host_deps_repo(
    name = REPO_NAME,
    extra_attrs_for_targets_as_json = {
        key: json.encode(value)
        for key, value in extra_attrs.items()
    }
)

"""

def make_repo_rule_function(
    bins: Dict[str, Binary],
    store: SharedObjectStore,
    args: argparse.Namespace,
) -> str:
    out = ["def create_symlinks(rctx):"]
    out.append("""\
    '''Creates symlinks for the binaries + shared objects modeled in this file.

    Args:
        rctx: repository context object
    '''""")
    p = lambda lines: out.extend(("    " + line).rstrip() for line in lines.splitlines())

    def make_symlinks(paths: Iterable[Path]) -> Iterable[str]:
        for path in paths:
            assert path.is_absolute()
            src = str(path)
            dest = src[1:] # assumes unix...
            yield f"""rctx.symlink("{src}", "{dest}")\n"""


    p("### .bzl Files")
    p(f"""rctx.symlink(Label("@@//{args.package}:{args.file_path}"), "info.bzl")""")
    p("\n\n")

    p("### Libraries")
    lib_paths = [ p for so in store.values() for p in [so.path] + list(so.aliases) ]
    for line in make_symlinks(lib_paths): p(line)
    p("\n\n")

    p("### Binaries")
    for line in make_symlinks(map(lambda b: b.path, bins.values())): p(line)
    p("\n\n")

    p("### Extra")
    p("for src, dest in EXTRA_SYMLINKS.items(): rctx.symlink(src, dest)")
    p("\n\n")

    # Add in the repo rule and we're done:
    return "\n".join(out) + REPO_RULE

SELF_INVOKE_RULE = r"""
def _mk_regen_script(ctx):
    script = ctx.executable.script
    script_runfiles = ctx.attr.script[DefaultInfo].default_runfiles

    # `run` will always set `PWD` to the main repo's dir under this target's
    # runfiles directory: https://github.com/bazelbuild/bazel/issues/2579#issuecomment-626840214
    #
    # to offer a way for other targets to invoke this script, we read
    # `RUNFILES_DIR`, if set:
    args = [
        '"${{RUNFILES_DIR-"."}}/{}"'.format(script.short_path),
            "--repo-name '{}'".format(ctx.attr.repo_name),
            "--package '{}'".format(ctx.attr.package),
            "--file-path '{}'".format(ctx.attr.file_path),
            "--package-within-main-repo-for-script '{}'".format(ctx.attr.script_package),
            "--file-path-within-package-for-script '{}'".format(ctx.attr.script_file_path),
            "--target-name-within-package-for-script '{}'".format(ctx.attr.script_target_name),
            "--show-diff",
    ] + [
        "'{}'".format(bin) for bin in ctx.attr.binaries
    ] + [
        "--extra-binary '{}'".format(bin) for bin in ctx.attr.extra_binaries
    ] + [
        "--fuzzy-dep-path '{}'".format(path) for path in ctx.attr.fuzzy_dep_paths
    ] + [ '"${@}"' ]

    out = "#!/usr/bin/env bash\n"
    out += "exec {}".format(" \\\n    ".join(args))

    update_script = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(update_script, out, is_executable = True)

    runfiles = (
        ctx.runfiles([ctx.executable.script, ctx.file.current_info_file])
            .merge(script_runfiles)
    )
    return [
        DefaultInfo(executable = update_script, runfiles = runfiles)
    ]

make_regenerate_script = rule(
    implementation = _mk_regen_script,
    attrs = {
        "script": attr.label(
            executable = True,
            cfg = "exec",
        ),
        "current_info_file": attr.label(allow_single_file = True), # just for dep tracking purposes
        "binaries": attr.string_list(allow_empty = True),
        "extra_binaries": attr.string_list(allow_empty = True),
        "fuzzy_dep_paths": attr.string_list(allow_empty = True),
        "repo_name": attr.string(),
        "package": attr.string(),
        "file_path": attr.string(),
        "script_package": attr.string(),
        "script_file_path": attr.string(),
        "script_target_name": attr.string(),
    },
    executable = True,
)
"""

def make_build_file_function(
    bins: Dict[str, Binary],
    store: SharedObjectStore,
    labels: Dict[str, DynamicExecutable],
    args: argparse.Namespace,
) -> str:
    # invert the labels map:
    labels: Dict[Path, str] = {
        entry.path: label for label, entry in labels.items()
    }
    assert len(labels) == len(bins) + len(store)

    out = []
    out.append("# buildifier: disable=unnamed-macro")
    out.append("def define_targets(filegroup, sh_binary, extra_attrs = {}):")
    out.append("""\
    '''Creates `filegroup`/`sh_binary` targets for the shared objects/binaries modeled.

    Also creates a target that, when run, regenerates this file.

    Args:
        filegroup: `filegroup`-like rule to use for shared object targets
            Unless you have specific requirements, use `native.filegroup`.
        sh_binary: `sh_binaries`-like rule to use for binary targets
            Unless you have specific requirements, use `sh_binaries` from
            `@rules_sh//sh:sh.bzl`.
        extra_attrs: Extra attributes (i.e. constraints, tags) to pass the
            `filegroup` and `sh_binary` rule invocations.
    '''""")
    p = lambda lines: out.extend(("    " + line).rstrip() for line in lines.splitlines())

    def repo_relative_path(path: Path) -> str:
        assert path.is_absolute()
        return ":" + str(path)[1:] # assumes unix (abs paths starting with /)...

    def make_dep_list(item: DynamicExecutable, labels: Dict[Path, str]) -> str:
        deps = "[]"
        if item.deps:
            deps = "[\n"

            for i, (shortname, path, abspath) in enumerate(item.deps):
                if i: deps += "\n"

                dep_label = labels[abspath]
                deps += f"""        # `{shortname}` as `{path}`\n"""
                deps += f"""        ":{dep_label}",\n"""

            deps += "    ]"

        return deps

    def make_label_list(items: Iterable[DynamicExecutable], labels: Dict[Path, str]) -> str:
        all = "[\n"
        for item in items:
            label = labels[item.path]
            all += f"""        ":{label}",\n"""
        all += "    ]"

        return all

    # Libraries first:
    p("### Libraries:")
    p("filegroup_ = lambda *args, **kw: filegroup(")
    p("    *args,")
    p("    **(kw | (")
    p("        {'data': kw.get('data', []) + EXTRA_LIB_DATA_DEPS.get(kw['srcs'][0], []) }")
    p("        if 'srcs' in kw else {}")
    p("    ) | extra_attrs),")
    p(")")
    p("")
    for shared_object in store.values():
        label = labels[shared_object.path]
        src = repo_relative_path(shared_object.path)
        fuzziness = " # NOTE: fuzziness requested" * shared_object.is_fuzzy

        aliases = ""
        if shared_object.aliases:
            aliases = " + [\n"
            aliases += "        # Symlinks:\n"
            for alias in shared_object.aliases:
                aliases += f"""        "{repo_relative_path(alias)}",\n"""

            aliases += "    ]"

        deps = make_dep_list(shared_object, labels)

        p(f"""\
filegroup_(
    name = "{label}",{fuzziness}
    srcs = [ "{src}" ]{aliases},
    data = {deps},
)
""")
    # emit "all-libraries" filegroup:
    all_libraries = make_label_list(store.values(), labels)
    p(f"""\
filegroup_(
    name = "all-libraries",
    data = {all_libraries},
)
""")
    p("\n\n")

    # Binaries next:
    p("### Binaries:")
    p("sh_binary_ = lambda *args, **kw: sh_binary(")
    p("    *args,")
    p("    **(kw | extra_attrs),")
    p(")")
    p("")

    # note: we don't distinguish between aliases when listing the deps of a
    # binary
    #
    # i.e. if `/bin/ls` depends on `/lib64/libc.so` but there's also a
    # `/lib64/libc.so.6` and a `/lib64/libc.so.6.2` that form a symlink chain,
    # we'll create one filegroup for `libc` with all of these files and list the
    # entire filegroup as a dep of `/bin/ls`
    #
    # this is technically wasteful (the sandbox will bind mount in three files
    # instead of one) but I think it's probably fine for now
    #
    # to do the "right thing" here we'd need to track the symlink chains instead
    # of just having a flat list of aliases
    for bin in bins.values():
        label = labels[bin.path]
        src = repo_relative_path(bin.path)

        shared_object_deps = make_dep_list(bin, labels)
        p(f"""\
sh_binary_(
    name = "{label}",
    srcs = ["{src}"],
    data = {shared_object_deps},
)
""")
    # "all-binaries":
    all_binaries = make_label_list(bins.values(), labels)
    p(f"""\
sh_binary_(
    name = "all-binaries",
    deps = {all_binaries}
)
""")

    # Finally, a target to reinvoke this script to regenerate the file:
    p("\n\n")
    p("### Runnable target to regenerate:")
    p(f"""\
make_regenerate_script(
    name = "regenerate",
    script = "@@//{args.package_within_main_repo_for_script}:{args.target_name_within_package_for_script}",
    current_info_file = "//:info.bzl",
    binaries = BINARIES,
    extra_binaries = EXTRA_BINARIES,
    fuzzy_dep_paths = FUZZY_DEP_PATHS,
    repo_name = REPO_NAME,
    package = "{args.package}",
    file_path = "{args.file_path}",
    script_package = "{args.package_within_main_repo_for_script}",
    script_file_path = "{args.file_path_within_package_for_script}",
    script_target_name = "{args.target_name_within_package_for_script}",
)
""")

    return "\n".join(out)

# perhaps have this function suggest running regen on lookup failure?
def make_binary_label_lookup_function(
    bins: Dict[str, Binary],
    labels: Dict[str, DynamicExecutable],
    _args: argparse.Namespace,
) -> str:
    # invert the labels map:
    binary_labels: Dict[Path, str] = {
        entry.path: label
        for label, entry in labels.items()
        if str(entry.path) in bins
    }
    assert len(binary_labels) == len(bins)

    out = ["def get_label_for_binary_path(binary_path):"]
    p = lambda lines: out.extend(("    " + line).rstrip() for line in lines.splitlines())

    p("PATH_TO_TARGET_NAME = {")
    for path, label_target_name in binary_labels.items():
        p(f"    '{str(path)}': '{label_target_name}',")
        pass
    p("}")

    p("\n")
    p("""return Label("@{}//:{}".format(REPO_NAME, PATH_TO_TARGET_NAME[binary_path]))""")

    return "\n".join(out)

DIVIDER = "#" * 80
BEGIN_PRESERVED = "# begin: preserved"
END_PRESERVED = "# end: preserved"

def extract_preserved_section(path: Path) -> Optional[str]:
    if path.exists():
        info(f"extracting preserved section from: {BLUE}{path}{RESET}")
        current = path.read_text().splitlines()

        divider = "#" * 80
        if BEGIN_PRESERVED in current and END_PRESERVED in current:
            begin = current.index(BEGIN_PRESERVED)
            end = current.index(END_PRESERVED)

            if begin < end and current[begin - 1] == DIVIDER and current[end + 1] == DIVIDER:
                return "\n".join(current[begin - 1 : end + 2])
    return None


BLANK_PRESERVED_SECTION = f"""\
{DIVIDER}
{BEGIN_PRESERVED}

# Preserved Section
#
# The contents of this section are preserved verbatim.

# Extra binaries to pass to `update_shared_libs.py`.
#
# These will not land in `BINARIES` in the regenerated version of this file; use
# this for binary paths that, for example, come from non-constant starlark
# constructs.
EXTRA_BINARIES = []

# Extra symlinks for the repository rule to create.
#
# Map from source path to (repo relative) dest path.
EXTRA_SYMLINKS = {{}}

# Extra data dependencies to add to the library filegroups.
#
# Map from the absolute realpath label of the library to a list of labels.
EXTRA_LIB_DATA_DEPS = {{}}

# Paths to symlinks that should *not* be resolved further when encountered.
#
# This can be used to paper over differences in exact versions of shared objects
# between machines.
FUZZY_DEP_PATHS = []

{END_PRESERVED}
{DIVIDER}
"""

def process_output(args: argparse.Namespace, output: str):
    # Find output path:
    base_path: Path
    if args.path_to_main_repo:
        base_path = Path(args.path_to_main_repo)
    else:
        # we're assuming this script is in the main repo...
        #
        # we use `resolve` to resolve symlinks (i.e. if argv0 is a symlink to
        # this file that's sitting in the runfiles dir of some bazel target)
        base_path = Path(sys.argv[0]).resolve()

        # remove the package path and the file path within the package
        repo_relative_script_path = os.path.join(
            args.package_within_main_repo_for_script,
            args.file_path_within_package_for_script,
        )

        assert str(base_path).endswith(repo_relative_script_path)
        base_path = Path(str(base_path).removesuffix(repo_relative_script_path))

    # tack on the package and file path:
    base_path = Path(os.path.join(
        base_path,
        args.package,
        args.file_path,
    ))

    # If the file already exists, copy its preserved section:
    pres = prev if (prev := extract_preserved_section(base_path)) else BLANK_PRESERVED_SECTION
    output = output.replace("{PRESERVED_SECTION}", pres, 1)

    # diff, if applicable:
    if args.show_diff and base_path.exists():
        # write out to temp file:
        with NamedTemporaryFile() as tmp:
            tmp.write(output.encode('utf-8'))

            if delta := shutil.which("delta"):
               subprocess.run([delta, "-s", base_path, tmp.name])
            elif colordiff := shutil.which("colordiff"):
                subprocess.run([colordiff, "-y", base_path, tmp.name])
            elif diff := shutil.which("diff"):
                subprocess.run([diff, "-y", base_path, tmp.name])
            else:
                warn("skipping diff; no suitable diff tool found")

    # emit:
    if args.emit_on_stdout:
        print(output, end = '', file = sys.stdout)
    else:
        with open(base_path, 'w') as f:
            f.write(output)
        print(f"Wrote out to {BLUE}`{base_path}`{RESET}", file = sys.stderr)

def main(args: argparse.Namespace):
    binaries = args.host_binaries + args.extra_binary
    repo_name = args.repo_name
    fuzzy_dep_paths = { Path(d): False for d in args.fuzzy_dep_path }

    store = SharedObjectStore()
    bins = {}

    # Process the binaries:
    for bin in binaries:
        bins[bin] = process_file(bin, store, fuzzy_dep_paths)
        # bins[bin] = run_lddtree(bin, store) # obviated

    # Check that all fuzzy dep paths were used:
    for d, u in fuzzy_dep_paths.items():
        if not u: crit(f"fuzzy dep path `{d}` was not encountered!")

    # Check for collisions, assign labels:
    check_for_collisions(bins, store)
    labels: Dict[str, DynamicExecutable] = assign_labels(bins, store)

    binaries = "\n    ".join(f"""\"{bin}\",""" for bin in args.host_binaries)
    output = f"""\
'''Description of host binaries and their shared object dependencies.

NOTE: Generated by `update_shared_libs.py`; prefer rerunning the script to
modifying this file manually.

Run as: `bazel run @{repo_name}//:regenerate`
(Note: you may need to uncomment the `use_repo` for `{repo_name}` in
MODULE.bazel first; alternatively look for an alias in the package where this
file lives)

You can also pass `-- <extra binaries to add>` to the above invocation.
'''

{{PRESERVED_SECTION}}

REPO_NAME = "{repo_name}"

# Modifications to this list *will* persist when you run `:regenerate`.
#
# However, comments and starlark constructs will *not* be preserved. See
# `EXTRA_BINARIES` above if this is required.
BINARIES = [
    {binaries}
]

{SELF_INVOKE_RULE}
"""

    output += "\n\n"
    output += make_repo_rule_function(bins, store, args)
    output += "\n\n"
    output += make_build_file_function(bins, store, labels, args)
    output += "\n\n"
    output += make_binary_label_lookup_function(bins, labels, args)
    output += "\n"

    process_output(args, output)


if __name__ == "__main__": main(parser.parse_args())

# ------------

# misc: is using `@local_nix//:store` as a dep viable?
#   - will bazel go and try to hash the entire store?
#   - answer: haven't done testing with the hermetic sandbox but the dep
#     machinery seems to deal with it okay; no full hashing
#
#  - unrelated: a fun side-effect of bazel having a `--sandbox_add_mount_pair`
#    flag is that we could actually have it effectively be `nix-user-chroot` for
#    us... i.e. we could make it mount in `/nix/store` for us. this would allow
#    us to have the build use nix tools...
#
#    I don't think we should _actually_ do this (being able to run build
#    invocations outside of the sandbox is a useful property...) but it's fun to
#    think about
