# Default BUILD file template for mix packages
DEFAULT_BUILD_FILE_CONTENT = """\
package(default_visibility = ["//visibility:public"])

load("@rules_elixir//:defs.bzl", "mix_library")

# A little ugly, but lets us keep a relatively-consistent interface to
# rules_erlang
alias(
    name = "erlang_app",
    actual = ":{app_name}",
)

mix_library(
    name = "{app_name}",
    app_name = "{app_name}",
    include = glob([
        "include/**/*.hrl",
    ], allow_empty = True),
    srcs = glob([
        "lib/**/*.ex",
        "lib/**/*.exs",
    ], allow_empty = True),
    deps = {explicit_deps_str},
    mix_config = ":mix.exs",
)
"""

def format_deps_str(deps_list):
    quoted_strings = [
        "\"{}\"".format(dep) for dep in deps_list
    ]

    return "[" + ", ".join(quoted_strings) + "]"

