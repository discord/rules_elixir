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
    "ELIXIR_RELEASE_DIR_PATH": "$(ELIXIR_RELEASE_DIR_PATH)",
    "ELIXIR_RELEASE_DIR_SHORT_PATH": "$(ELIXIR_RELEASE_DIR_SHORT_PATH)",
}

def _impl(ctx):
    otpinfo = ctx.toolchains["//:toolchain_type"].otpinfo
    elixirinfo = ctx.toolchains["//:toolchain_type"].elixirinfo
    # Always define every key any env map references; "" for the inapplicable
    # half (external vs relocatable). None would fail TemplateVariableInfo, and
    # "" keeps the maps' $(...) refs expandable regardless of internal-ness.
    vars = {
        "OTP_VERSION": otpinfo.version,
        "OTP_VERSION_FILE_PATH": otpinfo.version_file.path,
        "OTP_VERSION_FILE_SHORT_PATH": otpinfo.version_file.short_path,
        "ERLANG_HOME": erlang_home(otpinfo),
        # External Elixir: absolute home. Internal/prebuilt: "" -- consumers
        # resolve it from ELIXIR_RELEASE_DIR_* (tree artifact, no analysis-time path).
        "ELIXIR_HOME": elixirinfo.elixir_home or "",
        "ELIXIR_VERSION_FILE_PATH": elixirinfo.version_file.path,
        "ELIXIR_VERSION_FILE_SHORT_PATH": elixirinfo.version_file.short_path,
        "ERLANG_RELEASE_DIR_PATH": otpinfo.release_dir.path if otpinfo.release_dir else "",
        "ERLANG_RELEASE_DIR_SHORT_PATH": otpinfo.release_dir.short_path if otpinfo.release_dir else "",
        "ELIXIR_RELEASE_DIR_PATH": elixirinfo.release_dir.path if elixirinfo.release_dir else "",
        "ELIXIR_RELEASE_DIR_SHORT_PATH": elixirinfo.release_dir.short_path if elixirinfo.release_dir else "",
    }

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
