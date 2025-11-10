defmodule CombineConfigs do
  @moduledoc """
  Combines multiple binary-encoded Elixir config files into a single output file.

  Each input file should contain a binary-encoded Erlang term in the format:
  {app_name, app_config} where app_name is an atom and app_config is a keyword list.

  Usage:
    combine_configs <OUTPUT_FILE> <INPUT_FILE> [<INPUT_FILE>...]

  The tool will:
  1. Read each input file as binary
  2. Decode the Erlang terms
  3. Group configs by app name
  4. Deep merge configs for the same app
  5. Write the combined config to the output file as binary-encoded Erlang term
  """

  def main(args) do
    case parse_args(args) do
      {:ok, output_file, input_files} ->
        case combine_configs(output_file, input_files) do
          :ok ->
            :ok
          {:error, reason} ->
            IO.puts(:stderr, "Error: #{reason}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, reason)
        IO.puts(:stderr, "")
        IO.puts(:stderr, usage())
        System.halt(1)
    end
  end

  defp parse_args([output_file | input_files]) when length(input_files) > 0 do
    {:ok, output_file, input_files}
  end

  defp parse_args(_) do
    {:error, "Invalid arguments"}
  end

  defp usage do
    """
    Usage: combine_configs <OUTPUT_FILE> <INPUT_FILE> [<INPUT_FILE>...]

    Combines multiple binary-encoded config files into a single output file.

    Arguments:
      OUTPUT_FILE  - Path to write the combined config
      INPUT_FILE   - One or more paths to input config files to merge
    """
  end

  defp combine_configs(output_file, input_files) do
    with {:ok, configs} <- read_and_decode_configs(input_files),
         merged <- merge_configs_by_app(configs),
         :ok <- write_output(output_file, merged) do
      :ok
    end
  end

  defp read_and_decode_configs(input_files) do
    results =
      input_files
      |> Enum.map(fn file ->
        with {:ok, content} <- read_file(file),
             {:ok, term} <- decode_binary(content, file) do
          validate_config_format(term, file)
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, _} = error -> error
      nil -> {:ok, Enum.map(results, fn {:ok, config} -> config end)}
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, content} ->
        {:ok, content}
      {:error, reason} ->
        {:error, "Failed to read file '#{file}': #{inspect(reason)}"}
    end
  end

  defp decode_binary(content, file) do
    try do
      term = :erlang.binary_to_term(content)
      {:ok, term}
    rescue
      ArgumentError ->
        {:error, "Failed to decode binary in file '#{file}': invalid Erlang term format"}
    end
  end

  defp validate_config_format({app_name, app_config}, file)
       when is_atom(app_name) and is_list(app_config) do
    if Keyword.keyword?(app_config) do
      {:ok, {app_name, app_config}}
    else
      {:error, "Invalid config format in file '#{file}': app_config must be a keyword list"}
    end
  end

  defp validate_config_format(_, file) do
    {:error, "Invalid config format in file '#{file}': expected {app_name, app_config} tuple"}
  end

  defp merge_configs_by_app(configs) do
    configs
    |> Enum.group_by(fn {app_name, _} -> app_name end)
    |> Enum.map(fn {app_name, app_configs} ->
      merged_config =
        app_configs
        |> Enum.map(fn {_, config} -> config end)
        |> Enum.reduce([], &deep_merge/2)

      {app_name, merged_config}
    end)
  end

  # Deep merge implementation following Elixir's Config.Reader.merge/2 pattern
  defp deep_merge(config1, config2) when is_list(config1) and is_list(config2) do
    if Keyword.keyword?(config1) and Keyword.keyword?(config2) do
      Keyword.merge(config1, config2, fn _key, val1, val2 ->
        deep_merge_values(val1, val2)
      end)
    else
      config2
    end
  end

  defp deep_merge(_, config2), do: config2

  defp deep_merge_values(val1, val2) do
    if Keyword.keyword?(val1) and Keyword.keyword?(val2) do
      deep_merge(val1, val2)
    else
      val2
    end
  end

  defp write_output(output_file, merged_configs) do
    # For multiple apps, we write a list of tuples
    # For a single app, we write just the tuple
    output_term = case merged_configs do
      [{_app_name, _config}] = [single] -> single
      multiple -> multiple
    end

    binary = :erlang.term_to_binary(output_term)

    case File.write(output_file, binary) do
      :ok ->
        :ok
      {:error, reason} ->
        {:error, "Failed to write output file '#{output_file}': #{inspect(reason)}"}
    end
  end
end