defmodule PlugSample.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PlugSample.Worker
    ]

    opts = [strategy: :one_for_one, name: PlugSample.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        IO.puts("PlugSample Application started successfully!")
        schedule_demo()
        {:ok, pid}
      error ->
        error
    end
  end

  defp schedule_demo do
    spawn(fn ->
      IO.puts("Scheduling demo...")
      Process.sleep(200)
      IO.puts("Running demo...")
      result = PlugSample.Worker.run_demo()
      IO.puts("Demo result: #{inspect(result)}")
      Process.sleep(500)
      System.halt(0)
    end)
  end
end