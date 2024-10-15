"""Home to `dedent`, `format`, `fmt_span`, `mk_info`, `mk_warn`, `emit`, and `error`."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

esc = ""
_e = lambda s: s.format(esc = esc)

# Matches the names in Bazel:
# https://github.com/bazelbuild/bazel/blob/12cf60e8551c171d70e96631cafc896c03036a0d/src/main/java/com/google/devtools/build/lib/util/io/AnsiTerminal.java#L29-L38
colors = struct(
    # Only foreground for now.
    BOLD = _e("{esc}[1m"),
    ITALICS = _e("{esc}[3m"),
    UNDERLINE = _e("{esc}[4m"),
    RED = _e("{esc}[31m"),
    GREEN = _e("{esc}[32m"),
    YELLOW = _e("{esc}[33m"),
    BLUE = _e("{esc}[34m"),
    MAGENTA = _e("{esc}[35m"),
    CYAN = _e("{esc}[36m"),
    GRAY = _e("{esc}[37m"),
    RESET = _e("{esc}[0m"),
)

def _fmt(fmt_string, *args, **kwargs):
    if type(fmt_string) != type(""): fmt_string = str(fmt_string)
    fmt_string = dedent(fmt_string)

    remove_newlines = kwargs.pop("remove_newlines", True)
    if remove_newlines:
        fmt_string = " ".join(fmt_string.splitlines())

    # If `span_ctx` is in `kwargs`, use it to span this message:
    if "span_ctx" in kwargs:
        ctx = kwargs["span_ctx"]

        if hasattr(ctx, "label"):
            kind = "target"
            info = ctx.label
        elif hasattr(ctx, "extension_metadata"):
            kind = colors.CYAN + "module extension" + colors.RESET
            info = None
        elif hasattr(ctx, "workspace_root"):
            kind = colors.MAGENTA + "repository rule" + colors.RESET
            info = ctx.attr.name
        else:
            kind = colors.RED + "unknown" + colors.RESET
            info = None

        gen_loc = getattr(getattr(ctx, "attr", {}), "generator_location", None) or None
        span = "In {kind}".format(kind = kind)
        if info: span += " {}{}{}".format(colors.BOLD, info, colors.RESET)
        if gen_loc: span += " (at {}{}{})".format(colors.GRAY, gen_loc, colors.RESET)
        span += ":"
        # pad to overwrite the span from print (in case this is an error):
        span += " " * (50 - len(span))
        span += "\n\n"

        fmt_string = (span + fmt_string)

    return fmt_string.format(*args, **kwargs)

format = lambda f, *a, **kw: _fmt(
    f, remove_newlines = kw.pop("remove_newlines", False), *a, **kw,
)

def _log_helper(name, color):
    def inner(fmt_string, *args, **kwargs):
        noheader = kwargs.pop("noheader", False)

        msg = _fmt(fmt_string, *args, **kwargs)
        if not msg.rstrip(' ').endswith("\n"): msg += "\n"

        # Every `print` statement is prefixed with `DEBUG: `; we wish to
        # swap out the `DEBUG: ` for `FROM:  `
        replace_header = "\r{grey}FROM:  {reset}\n".format(
            grey = colors.GRAY,
            reset = colors.RESET,
        )
        if noheader: replace_header = "\r"

        # Indent by the length of the level:
        level_indent = " " * (len("DEBUG: "))

        # If we've got a multi-line string, indent lines after the first.
        lines = msg.splitlines(True)
        if len([line for line in lines if line.strip() != ""]):
            msg = level_indent.join(lines)

        return "{header}{color}{name}:{padding}{reset} {msg}\n".format(
            header = replace_header,
            color = color,
            name = name,
            padding = " " * (5 - len(name)),
            reset = colors.RESET,
            msg = msg
        )

    return inner

# Colors should match Bazel:
# https://github.com/bazelbuild/bazel/blob/c3bcb9838e17d08da0b7f30cbb0e4e284506748b/src/main/java/com/google/devtools/build/lib/util/io/AnsiTerminalPrinter.java#L26-L35

# Note: these functions do not print!
#
# Suggested usage is to wrap them in a `print` at the callsite so that the span
# printed comes from the callsite instead of this file.
#
# What we really want is a `#[track_caller]` equivalent...
mk_info = _log_helper("INFO", colors.GREEN)
mk_warn = _log_helper("WARN", colors.MAGENTA)

# Re-export under a different name to signify _intent_ and to suppress the
# buildifer lint.
emit = print

# Prefer `emit(mk_info(...))` and `emit(mk_warn(...))` to these.
emit_info = lambda f, *a, **k: print(mk_info(f, *a, **k)) # buildifier: disable=print
emit_warn = lambda f, *a, **k: print(mk_warn(f, *a, **k)) # buildifier: disable=print

def error(fmt_string, *args, **kwargs):
    # span will be incorrect in the `print` statement below but we don't really
    # care; the full trace is printed out anyways..
    #
    # asking users to do `msg = error(...); print(msg); fail(msg)` so the spans
    # will be correct isn't practical
    #
    # we still want this print though so that the error is front and center
    #
    # so: to avoid confusing users, we just write over the span (noheader):
    formatted_msg = _log_helper("ERROR", colors.BOLD + colors.RED)(
        fmt_string, noheader = True, *args, **kwargs
    )

    # see `//build/bazel/utils:suppress_error_message_prints`; in some
    # situations (expected-failure analysis tests) we want to suppress the
    # following print:
    suppress_print = False
    if "span_ctx" in kwargs and hasattr(kwargs["span_ctx"], "attr"):
        ctx = kwargs["span_ctx"]
        if hasattr(ctx.attr, "_suppress_error_message_prints"):
            setting = ctx.attr._suppress_error_message_prints
            if BuildSettingInfo in setting:
                suppress_print = setting[BuildSettingInfo].value

    # buildifier: disable=print
    if not suppress_print: print(formatted_msg)

    msg = _fmt(fmt_string, *args, **kwargs)
    fail(msg)

# NOTE: with changes like this: https://github.com/bazelbuild/bazel/pull/19274
# in upstream using `str(...)` instead of just `print(..., ..., ...)` is
# actually materially worse. We'd want to have our print machinery delegate to
# `print` and `fail`'s "interpolation" instead of just using `fmt` to "fix"
# this deficiency...

def dedent(s):
    """Removes indentation from multi-line string literals.

    Takes the whitespace prefixing the first non-empty line and removes that
    much whitespace from every line in the input.

    This exists to allow writing multi-line strings at the indentation level of
    the surrounding code.

    This is similar to [`indoc`](https://github.com/dtolnay/indoc) though note
    that this function does **not** determine the largest common whitespace
    prefix; instead it uses the first non-empty line's whitespace prefix.

    Example:
        ```starlark
        dedent('''
        This is an example. This line will have no leading whitespace in the result.

        This line will also have no leading whitespace.
          - however, this line will retain two spaces of whitespace
        ''')
        ```

    Args:
        s: input multi-line string to remove whitespace from

    Returns:
        "dedent"-ed form of the input string
    """

    lines = s.splitlines()

    # skip empty leading lines:
    for i in range(0, len(lines)):
        if lines[i] == "":
            continue
        else:
            lines = lines[i:]
            break

    # find the leading whitespace prefix to strip:
    if len(lines) == 0: return ""
    first = lines[0]
    whitespace_prefix = first.removesuffix(first.lstrip())

    trailing = "\n" if s.endswith("\n") else ""
    return "\n".join([line.removeprefix(whitespace_prefix) for line in lines]) + trailing

################################################################################

def fmt_span(span_info, parens = True, prefix = "from "):
    """Formats a span that points at a particular location in a source file.

    Args:
        span_info: `None | file | Tuple[file, line num] | Tuple[file, line num, col num]`
            Where `file` is either a string (representing a path) or a `Label`.
        parens: boolean, indicates whether to put parentheses in the output
        prefix: word to put in front of the span

    Returns:
        Empty string or string of the form ` (from ...)`
    """

    file, line, col = None, None, None

    if span_info == None: pass
    elif type(span_info) == type([]) or type(span_info) == type(("tuple",)):
        n = len(span_info)
        if n == 0: pass
        elif n == 1: file = span_info[0]
        elif n == 2: file, line = span_info
        elif n == 3: file, line, col = span_info
        else: error("""
            invalid sequence for span: `{}`; can have up to three elements
            (file, line, column)
        """, span_info)
    elif type(span_info) == type(Label(":bogus")) or type(span_info) == type(""):
        file = span_info
    else: error("""
        invalid type for `span_info`: {} (type: {})
    """, span_info, type(span_info))

    # If `file` is a Label that's in the root repo, rewrite it to be a path;
    # this lets file span matchers (i.e. like those that VSCode uses to turn
    # paths in the terminal output into links) pick up the span:
    if type(file) == type(Label(":bogus")) and file.workspace_name == "":
        file = "{}/{}".format(file.package, file.name)

    if file == None: return ""

    B, R = colors.BOLD, colors.RESET
    return ' {lpar}{pref}"{B}{file}{R}"{line}{col}{rpar}'.format(
        B = B, R = R,
        file = file,
        line = ", line {B}{}{R}".format(line, B = B, R = R) if line else "",
        col = ", column {B}{}{R}".format(col, B = B, R = R) if col else "",

        pref = prefix,
        lpar = "(" if parens else "",
        rpar = ")" if parens else "",
    )
