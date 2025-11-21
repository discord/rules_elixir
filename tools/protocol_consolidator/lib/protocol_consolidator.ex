defmodule ProtocolConsolidator do
  @moduledoc """
  A Unix-style protocol consolidation tool for Elixir.

  Usage: consolidator <output_directory> input_ebin_dirs [...]

  This tool consolidates all protocols found in the input ebin directories
  and writes the consolidated beam files to the output directory.

  The consolidated beams must be loaded BEFORE the regular ebin directories
  in the code path to ensure they override the non-consolidated versions.

  Example:
    consolidator /path/to/consolidated /path/to/app1/ebin /path/to/app2/ebin

  At runtime, ensure the consolidated directory is first in the code path:
    erl -pa /path/to/consolidated -pa /path/to/app1/ebin -pa /path/to/app2/ebin ...
  """

  def main(args) do
    # Ensure Elixir application is started (needed for Protocol functions)
    {:ok, _} = Application.ensure_all_started(:elixir)

    # Convert charlists to strings if necessary
    string_args = Enum.map(args, fn
      arg when is_list(arg) -> List.to_string(arg)
      arg -> arg
    end)

    case parse_args(string_args) do
      {:ok, output_dir, input_dirs} ->
        consolidate(output_dir, input_dirs)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        System.halt(1)
    end
  end

  defp parse_args([]) do
    {:error, "Missing arguments. Usage: consolidator <output_directory> input_ebin_dirs [...]"}
  end

  defp parse_args([_output_dir]) do
    {:error, "Missing input directories. Usage: consolidator <output_directory> input_ebin_dirs [...]"}
  end

  defp parse_args([output_dir | input_dirs]) when length(input_dirs) > 0 do
    # Validate that input directories exist
    case validate_input_dirs(input_dirs) do
      :ok ->
        {:ok, output_dir, input_dirs}

      {:error, missing_dirs} ->
        {:error, "The following input directories do not exist: #{Enum.join(missing_dirs, ", ")}"}
    end
  end

  defp validate_input_dirs(dirs) do
    missing_dirs = Enum.filter(dirs, fn dir -> not File.dir?(dir) end)

    if Enum.empty?(missing_dirs) do
      :ok
    else
      {:error, missing_dirs}
    end
  end

  defp consolidate(output_dir, input_dirs) do
    # Create output directory if it doesn't exist
    File.mkdir_p!(output_dir)

    # Convert paths to charlists as required by Protocol functions
    input_paths = Enum.map(input_dirs, &to_charlist/1)

    # Extract all protocols from all input paths
    protocols = Protocol.extract_protocols(input_paths)

    if Enum.empty?(protocols) do
      IO.puts("No protocols found in the specified directories.")
      System.halt(0)
    end

    IO.puts("Found #{length(protocols)} protocol(s) to consolidate")

    # Process each protocol and collect results
    {consolidated_count, failed_count} =
      Enum.reduce(protocols, {0, 0}, fn protocol, {consolidated, failed} ->
        IO.write("  Consolidating #{inspect_protocol(protocol)}... ")

        # Extract all implementations for this protocol across all paths
        impls = Protocol.extract_impls(protocol, input_paths)

        # Ensure the protocol module is loaded from our input paths
        # This is necessary for Protocol.consolidate to find the beam file
        ensure_module_loaded(protocol, input_dirs)

        # Consolidate the protocol with all its implementations
        case Protocol.consolidate(protocol, impls) do
          {:ok, binary} ->
            # Write the consolidated beam file to the output directory
            output_path = Path.join(output_dir, "#{Atom.to_string(protocol)}.beam")
            File.write!(output_path, binary)
            IO.puts("done (#{length(impls)} implementations)")
            {consolidated + 1, failed}

          {:error, :not_a_protocol} ->
            IO.puts("skipped (not a protocol)")
            {consolidated, failed + 1}

          {:error, :no_beam_info} ->
            IO.puts("failed (no beam info)")
            {consolidated, failed + 1}

          {:error, reason} ->
            IO.puts("failed (#{inspect(reason)})")
            {consolidated, failed + 1}
        end
      end)

    # Print summary
    IO.puts("\nSummary:")
    IO.puts("  Successfully consolidated: #{consolidated_count}")

    if failed_count > 0 do
      IO.puts("  Failed: #{failed_count}")
    end

    IO.puts("  Output directory: #{output_dir}")

    # Exit with appropriate code
    if failed_count > 0 do
      System.halt(1)
    else
      System.halt(0)
    end
  end

  # Helper to safely inspect protocol names without using the protocol itself
  defp inspect_protocol(protocol) when is_atom(protocol) do
    # Use Macro.inspect_atom to avoid calling the protocol's inspect implementation
    # which might not be available during consolidation
    Macro.inspect_atom(:literal, protocol)
  end

  defp ensure_module_loaded(module, paths) do
    # First, add all input directories to the code path
    for path <- paths do
      :code.add_patha(to_charlist(path))
    end

    # Try to ensure the module is loaded
    case Code.ensure_loaded(module) do
      {:module, _} -> :ok
      _ -> :ok  # Continue even if not loaded, Protocol.consolidate will handle it
    end
  end
end