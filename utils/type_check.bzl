
load(":strings.bzl", "error")
load("@bazel_skylib//lib:types.bzl", "types")

# inner ty can be a string with a typename (returned by `type(...)` or a list
# of strings)
def list_type_check(name, val, inner_ty, extra_context = ""):
    if type(inner_ty) == type(type(0)):
        chk = lambda other: other == inner_ty
        err = "of type `{}`".format(inner_ty)
    elif types.is_list(inner_ty):
        chk = lambda other: other in inner_ty
        err = "one of these types: `{}`".format(inner_ty)
    else: fail("invalid `inner_ty`")

    if not types.is_list(val):
        error("`{}` must be a list, got: `{}`", name, val)

    for i, x in enumerate(val):
        val_type = type(x)
        if not chk(val_type):
            error("""
                elements of `{name}`{extra_context} must be {expected} but got
                `{val}` (of type `{val_type}`) for element at index `{idx}`
            """,
                name = name, val = x, val_type = val_type, idx = i,
                expected = err, extra_context = extra_context,
            )

def type_check(name, val, ty, extra_context = ""):
    if type(ty) == type(type(0)):
        chk = lambda other: other == ty
        err = "of type `{}`".format(ty)
    elif types.is_list(ty):
        chk = lambda other: other in ty
        err = "one of these types: `{}`".format(ty)
    else: fail("invalid `ty`")

    val_type = type(val)
    if not chk(val_type): error("""
        argument `{n}`{extra_context} must be {expected} but got `{val}` (of
        type `{val_type}`)
    """, n = name, val = val, expected = err, val_type = val_type,
        extra_context = extra_context,
    )
