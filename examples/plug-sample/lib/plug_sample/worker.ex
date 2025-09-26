defmodule PlugSample.Worker do
  use GenServer

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def run_demo do
    GenServer.call(__MODULE__, :run_demo, 30000)
  end

  @impl true
  def init(_args) do
    IO.puts("PlugSample.Worker initialized")
    Process.send_after(self(), :auto_run_demo, 100)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:run_demo, _from, state) do
    IO.puts("\nStarting PlugSample crypto demonstration...\n")

    secret = "my-secret-key-#{:os.system_time(:millisecond)}"
    message = "hello world"

    Enum.each(1..5, fn iteration ->
      IO.puts("--- Iteration #{iteration} ---")

      key = PlugSample.generate_key(secret, "iteration-#{iteration}")
      IO.puts("Generated key: #{Base.encode64(key) |> String.slice(0..20)}...")

      signed = PlugSample.sign_message(message, secret)
      IO.puts("Signed message: #{String.slice(signed, 0..50)}...")

      case PlugSample.verify_message(signed, secret) do
        {:ok, verified_msg} ->
          IO.puts("Verified message: #{verified_msg}")
        :error ->
          IO.puts("Failed to verify message!")
      end

      encrypted = PlugSample.encrypt_message(message, key)
      IO.puts("Encrypted: #{String.slice(encrypted, 0..50)}...")

      case PlugSample.decrypt_message(encrypted, key) do
        {:ok, decrypted} ->
          IO.puts("Decrypted: #{decrypted}")
        :error ->
          IO.puts("Failed to decrypt message!")
      end

      IO.puts("")
      Process.sleep(100)
    end)

    IO.puts("Demonstration complete!")

    {:reply, :ok, state}
  end
end