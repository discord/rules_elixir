defmodule ElixirReleaseDemo.Server do
  @moduledoc """
  A simple GenServer for demonstration purposes.
  Shows configuration handling and runtime behavior.
  """

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Read configuration at startup
    config = Application.get_all_env(:elixir_release_demo)
    Logger.info("ElixirReleaseDemo.Server started with config: #{inspect(config)}")

    # Schedule periodic work
    schedule_work()

    {:ok, %{counter: 0, config: config}}
  end

  @impl true
  def handle_info(:work, state) do
    counter = state.counter + 1
    Logger.info("ElixirReleaseDemo: Doing work ##{counter}")

    # Check if we have runtime configuration
    if runtime_value = Application.get_env(:elixir_release_demo, :runtime_value) do
      Logger.info("Runtime configuration value: #{inspect(runtime_value)}")
    end

    # Schedule next work
    schedule_work()

    {:noreply, %{state | counter: counter}}
  end

  defp schedule_work() do
    # Schedule work every 10 seconds
    Process.send_after(self(), :work, 10_000)
  end
end