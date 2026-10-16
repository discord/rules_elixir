# The heavy-mode tests fetch from a local repository with the git on PATH.
# The analyser tests decode its output with JSON, which Elixir 1.18 added.
available = [git: System.find_executable("git") != nil, json: Code.ensure_loaded?(JSON)]
ExUnit.start(exclude: for({tag, false} <- available, do: tag))
