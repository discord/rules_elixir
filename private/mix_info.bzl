MixProjectInfo = provider(
    doc = "Metadata specific to a Mix project build",
    fields = {
        # *most* of this, other than the path to mix.exs, should be provided by
        # ErlangAppInfo
        # 'app_name': 'Name of the OTP application',
        "mix_config": "Path to the mix.exs file of this Mix project",
        "mix_env": "The MIX_ENV used to compile this project (prod, test, dev)",
        # 'ebin': 'Directory containing built libs(???)',
        # # TODO: find out how elixir works
        # 'consolidated': 'Directory containing...consolidated...stuff??? how does elixir work?',
        # 'deps': 'Compiled BEAM dependencies of this thing',
    },
)

ErlangCompilationContext = provider(
    fields = {
        "deps": "packages that were used to compile this thing",
    },
)
