"""Public API for mix_library rule.

The mix_library rule compiles Elixir code using Mix and creates an Erlang application.
It automatically includes common dependencies (hex, elixir, logger) unless building hex itself.
"""

load("//private:mix_library.bzl", _mix_library = "mix_library")

def mix_library(*args, **kwargs):
    """Compiles an Elixir library using Mix.

    Automatically adds dependencies for hex, elixir, and logger unless the
    app_name is "hex" (to avoid circular dependencies).

    Args:
        *args: Positional arguments passed to the underlying rule
        **kwargs: Keyword arguments passed to the underlying rule
    """
    deps = kwargs.get("deps", [])
    if kwargs.get("app_name") != "hex":
        deps.extend([
            Label("@hex_pm//:lib"),
            Label("//elixir:elixir"),
            Label("//elixir:logger"),
        ])
    kwargs["deps"] = deps
    _mix_library(*args, **kwargs)
