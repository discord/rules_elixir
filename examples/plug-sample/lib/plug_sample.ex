defmodule PlugSample do
  def generate_key(secret, salt \\ "signed cookie") do
    Plug.Crypto.KeyGenerator.generate(secret, salt)
  end

  def sign_message(message, secret) do
    Plug.Crypto.sign(secret, "signing salt", message)
  end

  def verify_message(signed_message, secret) do
    Plug.Crypto.verify(secret, "signing salt", signed_message)
  end

  def encrypt_message(message, secret) do
    Plug.Crypto.MessageEncryptor.encrypt(message, secret, "encryption salt")
  end

  def decrypt_message(encrypted, secret) do
    Plug.Crypto.MessageEncryptor.decrypt(encrypted, secret, "encryption salt")
  end
end