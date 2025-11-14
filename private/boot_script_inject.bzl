"""Helpers for injecting Config.Provider.boot() into Erlang boot scripts.

This module provides functions to modify Erlang boot scripts to automatically
call Config.Provider.boot() BETWEEN stdlib and compiler (before Elixir starts),
ensuring runtime configuration is loaded at the correct point in the boot sequence.
This matches Mix release behavior where Config.Provider runs early in boot.
"""

def inject_config_provider_boot_action(ctx, original_boot, output_boot):
    """Create an action that injects Config.Provider.boot() into a boot script.

    Args:
        ctx: Rule context
        original_boot: Original boot script file
        output_boot: Output boot script file with injection

    The injection adds:
        {apply, {'Elixir.Config.Provider', boot, []}}
    between stdlib and compiler in the boot sequence (before Elixir starts).
    """

    # Create a script to modify the boot file
    script = """
#!/bin/bash
set -euo pipefail

ORIG_BOOT="{original}"
OUTPUT_BOOT="{output}"

# Read the original boot script as Erlang terms
erl -noshell -eval '
    {{ok, [Boot]}} = file:consult("{original}"),
    {{script, {{Name, Version}}, Instructions}} = Boot,

    % Find where stdlib starts and inject Config.Provider.boot() after it (before compiler)
    NewInstructions = inject_after_stdlib(Instructions, []),

    % Write the modified boot script
    NewBoot = {{script, {{Name, Version}}, NewInstructions}},
    {{ok, File}} = file:open("{output}", [write]),
    io:format(File, "~p.~n", [NewBoot]),
    file:close(File),
    halt(0).

inject_after_stdlib([], Acc) ->
    lists:reverse(Acc);
inject_after_stdlib([{{apply, {{application, start_boot, [stdlib, permanent]}}}}, Rest | T], Acc) ->
    % Found stdlib start, inject Config.Provider.boot() after it (before compiler)
    ConfigProviderBoot = {{apply, {{\\'Elixir.Config.Provider\\', boot, []}}},
    lists:reverse(Acc) ++ [{{apply, {{application, start_boot, [stdlib, permanent]}}}}, ConfigProviderBoot, Rest | T];
inject_after_stdlib([H | T], Acc) ->
    inject_after_stdlib(T, [H | Acc]).
' || exit 1
""".format(
        original = original_boot.path,
        output = output_boot.path,
    )

    ctx.actions.run_shell(
        inputs = [original_boot],
        outputs = [output_boot],
        command = script,
        mnemonic = "BootInject",
        progress_message = "Injecting Config.Provider.boot() into boot script",
    )

def create_boot_injection_instructions(ctx, output_file):
    """Create a file with boot injection instructions for manual integration.

    Args:
        ctx: Rule context
        output_file: Output file for injection instructions

    This creates a file documenting how to manually inject Config.Provider.boot()
    into a boot script if automatic injection isn't used.
    """

    content = """
# Boot Script Injection Instructions

To enable automatic Config.Provider.boot() invocation, add the following
instruction to your boot script between stdlib and compiler (before Elixir starts):

    {apply, {'Elixir.Config.Provider', boot, []}}

## Example Boot Script Fragment

    {progress, starting_applications},
    {apply, {application, start_boot, [kernel, permanent]}},
    {apply, {application, start_boot, [stdlib, permanent]}},
    {apply, {'Elixir.Config.Provider', boot, []}},  % <-- Add this line BEFORE compiler
    {apply, {application, start_boot, [compiler, permanent]}},
    {apply, {application, start_boot, [elixir, permanent]}},
    {apply, {application, start_boot, [your_app, permanent]}},

## What This Does

1. After stdlib starts (but before Elixir), Config.Provider.boot() is called
2. It checks for runtime configuration (runtime.exs)
3. If found, evaluates it with current environment variables
4. Merges with compile-time config from sys.config
5. If reboot_system_after_config is true, restarts the VM
6. Otherwise, applies configuration and continues boot

## Alternative: Command Line

You can also use -eval flag when starting the release:

    erl -eval 'Elixir.Config.Provider:boot()' -boot start -config sys

However, this has timing issues and the boot script injection is preferred.
"""

    ctx.actions.write(
        output = output_file,
        content = content,
    )

def should_inject_config_provider(ctx):
    """Determine if Config.Provider.boot() injection is needed.

    Args:
        ctx: Rule context with SysConfigInfo provider

    Returns:
        Boolean indicating if injection should be performed
    """
    if hasattr(ctx.attr, "sys_config"):
        sys_config_target = ctx.attr.sys_config
        if hasattr(sys_config_target, "SysConfigInfo"):
            return sys_config_target.SysConfigInfo.has_runtime_config
    return False