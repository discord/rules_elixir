defmodule ItestExample do
  @moduledoc """
  Example module for demonstrating integration testing framework.
  """

  @doc """
  Check if a service is available at the given URL.
  """
  def check_service(url) do
    case :httpc.request(:get, {to_charlist(url), []}, [], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
