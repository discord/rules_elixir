# The heavy-mode tests fetch from a local repository with the git on PATH.
ExUnit.start(exclude: if(System.find_executable("git"), do: [], else: [:git]))
