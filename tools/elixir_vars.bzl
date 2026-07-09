load(
    "@rules_erlang//tools:erlang_toolchain.bzl",
    "erlang_home",
)

ELIXIR_VARS_ENV_MAP = {
    "OTP_VERSION": "$(OTP_VERSION)",
    "OTP_VERSION_FILE_PATH": "$(OTP_VERSION_FILE_PATH)",
    "OTP_VERSION_FILE_SHORT_PATH": "$(OTP_VERSION_FILE_SHORT_PATH)",
    "ERLANG_HOME": "$(ERLANG_HOME)",
    "ELIXIR_HOME": "$(ELIXIR_HOME)",
    "ELIXIR_VERSION_FILE_PATH": "$(ELIXIR_VERSION_FILE_PATH)",
    "ELIXIR_VERSION_FILE_SHORT_PATH": "$(ELIXIR_VERSION_FILE_SHORT_PATH)",
}

# Consumers wanting to run erl should `export ERL_ROOTDIR="$PWD/$(ERLANG_RELEASE_DIR_PATH)"`
# (or _SHORT_PATH in a runfiles context) before invoking "$(ERLANG_HOME)"/bin/erl.
ELIXIR_VARS_ENV_MAP_INTERNAL = ELIXIR_VARS_ENV_MAP | {
    "ERLANG_RELEASE_DIR_PATH": "$(ERLANG_RELEASE_DIR_PATH)",
    "ERLANG_RELEASE_DIR_SHORT_PATH": "$(ERLANG_RELEASE_DIR_SHORT_PATH)",
}

def _impl(ctx):
    otpinfo = ctx.toolchains["//:toolchain_type"].otpinfo
    elixirinfo = ctx.toolchains["//:toolchain_type"].elixirinfo
    vars = {
        "OTP_VERSION": otpinfo.version,
        "OTP_VERSION_FILE_PATH": otpinfo.version_file.path,
        "OTP_VERSION_FILE_SHORT_PATH": otpinfo.version_file.short_path,
        "ERLANG_HOME": erlang_home(otpinfo),
        "ELIXIR_HOME": elixirinfo.elixir_home,
        "ELIXIR_VERSION_FILE_PATH": elixirinfo.version_file.path,
        "ELIXIR_VERSION_FILE_SHORT_PATH": elixirinfo.version_file.short_path,
    }
    if otpinfo.release_dir != None:
        vars["ERLANG_RELEASE_DIR_PATH"] = otpinfo.release_dir.path
        vars["ERLANG_RELEASE_DIR_SHORT_PATH"] = otpinfo.release_dir.short_path

    return [
        platform_common.TemplateVariableInfo(vars),
    ]

elixir_vars = rule(
    implementation = _impl,
    provides = [
        platform_common.TemplateVariableInfo,
    ],
    toolchains = ["//:toolchain_type"],
)
