defmodule PlugSample.CLI do
  @moduledoc """
  Main CLI module that demonstrates plug_crypto functionality
  """

  def main(_args \\ []) do
    IO.puts("Starting PlugSample crypto demonstration...\n")

    secret = "my-secret-key-#{:os.system_time(:millisecond)}"
    message = "hello world"

    Enum.each(1..5, fn iteration ->
      IO.puts("--- Iteration #{iteration} ---")

      # Generate a key
      key = PlugSample.generate_key(secret, "iteration-#{iteration}")
      IO.puts("Generated key: #{Base.encode64(key) |> String.slice(0..20)}...")

      # Sign the message
      signed = PlugSample.sign_message(message, secret)
      IO.puts("Signed message: #{String.slice(signed, 0..50)}...")

      # Verify the signature
      case PlugSample.verify_message(signed, secret) do
        {:ok, verified_msg} ->
          IO.puts("Verified message: #{verified_msg}")
        :error ->
          IO.puts("Failed to verify message!")
      end

      # Encrypt the message
      encrypted = PlugSample.encrypt_message(message, key)
      IO.puts("Encrypted: #{String.slice(encrypted, 0..50)}...")

      # Decrypt the message
      case PlugSample.decrypt_message(encrypted, key) do
        {:ok, decrypted} ->
          IO.puts("Decrypted: #{decrypted}")
        :error ->
          IO.puts("Failed to decrypt message!")
      end

      IO.puts("")

      # Small delay for readability
      Process.sleep(100)
    end)

    IO.puts("Demonstration complete!")
  end

  def run do
    main([])
  end
end