"""Configuration transitions for the //:mix_env build setting flag.

The //:mix_env flag drives MIX_ENV-aware compilation in mix_library and
mix_release. Three transitions live here:

- mix_env_to_test: outgoing-edge, applied by mix_test on its `lib` attribute.
  Flips //:mix_env to "test" so the consumed library compiles in test mode.

- mix_env_to_prod: outgoing-edge, applied by mix_library on `deps` (and by
  mix_release on `application`). Resets //:mix_env to "prod" so transitive
  dependencies don't inherit test mode from a top-level test compile.

- mix_env_attr_override: rule-level (incoming-edge), applied by mix_library
  and mix_release. When the rule has an explicit `mix_env` attribute set, it
  pins the flag to that value for the rule's own configuration — meaning any
  select()s on the rule's other attributes see the override.
"""

_MIX_ENV_FLAG = "//:mix_env"

def _to_test_impl(_settings, _attr):
    return {_MIX_ENV_FLAG: "test"}

mix_env_to_test = transition(
    implementation = _to_test_impl,
    inputs = [],
    outputs = [_MIX_ENV_FLAG],
)

def _to_prod_impl(_settings, _attr):
    return {_MIX_ENV_FLAG: "prod"}

mix_env_to_prod = transition(
    implementation = _to_prod_impl,
    inputs = [],
    outputs = [_MIX_ENV_FLAG],
)

def _attr_override_impl(settings, attr):
    override = getattr(attr, "mix_env", None)
    if override:
        return {_MIX_ENV_FLAG: override}
    return {_MIX_ENV_FLAG: settings[_MIX_ENV_FLAG]}

mix_env_attr_override = transition(
    implementation = _attr_override_impl,
    inputs = [_MIX_ENV_FLAG],
    outputs = [_MIX_ENV_FLAG],
)

def _release_attr_override_impl(_settings, attr):
    # mix_release is self-contained: its env is determined by its own
    # `mix_env` attribute (default "prod"). Ambient //:mix_env is intentionally
    # ignored so that `bazel build :my_release --//:mix_env=test` still yields
    # a prod release. The transitive `application` inherits this value.
    return {_MIX_ENV_FLAG: attr.mix_env or "prod"}

mix_env_release_attr_override = transition(
    implementation = _release_attr_override_impl,
    inputs = [],
    outputs = [_MIX_ENV_FLAG],
)
