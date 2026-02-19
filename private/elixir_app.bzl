load("@rules_erlang//:app_file2.bzl", "app_file")
load("@rules_erlang//:erlang_app.bzl", "DEFAULT_ERLC_OPTS")
load("@rules_erlang//:erlang_app_info.bzl", "erlang_app_info")
load("@rules_erlang//:erlang_bytecode.bzl", "erlang_bytecode")
load("@rules_erlang//:erlang_xrl_yrl.bzl", "erlang_xrl_yrl")
load("//private:elixir_bytecode.bzl", "elixir_bytecode")
load("//private:merge_beam_dirs.bzl", "merge_beam_dirs")
load("//private:erlang_app_filter_module_conflicts.bzl", "erlang_app_filter_module_conflicts")

def elixir_app(
        app_name = None,
        extra_apps = [],
        srcs = None,
        xrl_yrl_srcs = [],
        erl_srcs = [],
        erl_hdrs = [],
        erlc_opts = None,
        elixirc_opts = [],
        ez_deps = [],
        deps = [],
        data = [],
        priv = [],
        license_files = [],
        **kwargs):
    """compiles elixir sources in a manner compatible with @rules_erlang

    Args:
      app_name: Name of the application
      extra_apps: additional apps (elixir is always included) injected into
          the .app file
      srcs: Sources. Defaults to "lib/**/*.ex"
      xrl_yrl_srcs: List of .xrl and .yrl files to compile
      erl_srcs: List of .erl files to compile
      erl_hdrs: List of .hrl header files
      elixirc_opts: elixirc options
      ez_deps: Dependencies that are .ez files
      deps: ErlangAppInfo labels
      **kwargs: Additional args passed to the underlying app_file rule, such
          app_version, etc.

    Returns:
      Nothing
    """
    if srcs == None:
        srcs = native.glob([
            "lib/**/*.ex",
        ])

    # preprocess .xrl/.yrl files -> .erl
    erlang_generated_srcs = []
    if xrl_yrl_srcs:
        xrl_yrl_outs = []
        for src in xrl_yrl_srcs:
            if src.endswith(".xrl"):
                xrl_yrl_outs.append(src[:-4] + ".erl")
            elif src.endswith(".yrl"):
                xrl_yrl_outs.append(src[:-4] + ".erl")

        erlang_xrl_yrl(
            name = "xrl_yrl_generated",
            srcs = xrl_yrl_srcs,
            outs = xrl_yrl_outs,
        )
        erlang_generated_srcs = [":xrl_yrl_generated"]

    # compile any .erl files (incl any generated in previous step)
    erlang_beam = []
    if erl_srcs or erlang_generated_srcs:
        all_erl_srcs = erl_srcs + erlang_generated_srcs
        erlang_bytecode(
            name = "erlang_beam_files",
            srcs = all_erl_srcs,
            hdrs = erl_hdrs,
            deps = deps,
            data = data,
            dest = "erlang_ebin",
            erlc_opts = erlc_opts if erlc_opts != None else DEFAULT_ERLC_OPTS,
        )
        erlang_beam = [":erlang_beam_files"]

    # create .beam files from elixir source files
    elixir_bytecode(
        name = "beam_files",
        srcs = srcs,
        beam = erlang_beam,
        dest = "beam_files",
        elixirc_opts = elixirc_opts,
        ez_deps = ez_deps,
        deps = deps,
        data = data,
    )

    all_modules = [":beam_files"]
    if erlang_beam:
        all_modules = erlang_beam + all_modules

    # Provide a default description if not specified
    app_description = kwargs.pop("app_description", "An Elixir application")

    app_file(
        name = "app_file",
        out = "%s.app" % app_name,
        app_name = app_name,
        app_description = app_description,
        extra_apps = ["elixir"] + extra_apps,
        modules = all_modules,
        **kwargs
    )

    # bazel will not permit two rules to write to the same output directory;
    # create a merge rule so that we can combine these outputs.
    beam_dirs_to_merge = [":beam_files"]
    if erlang_beam:
        beam_dirs_to_merge = erlang_beam + beam_dirs_to_merge

    all_srcs = srcs + erl_srcs

    merge_beam_dirs(
        name = "ebin",
        beam_dirs = beam_dirs_to_merge,
        app_file = ":app_file",
        dest = "ebin",
        app_name = app_name,
        extra_apps = extra_apps,
        hdrs = erl_hdrs,
        srcs = all_srcs,
        priv = priv,
        license_files = license_files,
        deps = deps,
    )

    erlang_app_filter_module_conflicts(
        name = "elixir_without_app_overlap",
        dest = "unconsolidated",
        src = Label("@rules_elixir//elixir:elixir"),
        without = [":ebin"],
    )

    erlang_app_info(
        name = "erlang_app",
        srcs = all_srcs,
        hdrs = erl_hdrs,
        app_name = app_name,
        beam = [":ebin"],
        extra_apps = extra_apps,
        license_files = license_files,
        priv = priv,
        visibility = ["//visibility:public"],
        deps = [
            ":elixir_without_app_overlap",
        ] + deps,
    )
