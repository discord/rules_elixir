defmodule PlugSampleTest do
  use ExUnit.Case

  describe "PlugSample module" do
    test "module exists and is loaded" do
      assert Code.ensure_loaded?(PlugSample)
    end

    test "has expected functions defined" do
      assert function_exported?(PlugSample, :generate_key, 1)
      assert function_exported?(PlugSample, :generate_key, 2)
      assert function_exported?(PlugSample, :sign_message, 2)
      assert function_exported?(PlugSample, :verify_message, 2)
      assert function_exported?(PlugSample, :encrypt_message, 2)
      assert function_exported?(PlugSample, :decrypt_message, 2)
    end
  end

  describe "PlugSample.Application" do
    test "application module exists" do
      assert Code.ensure_loaded?(PlugSample.Application)
    end

    test "has start/2 callback defined" do
      assert function_exported?(PlugSample.Application, :start, 2)
    end
  end

  describe "PlugSample.Worker" do
    test "worker module exists" do
      assert Code.ensure_loaded?(PlugSample.Worker)
    end

    test "has start_link/1 defined" do
      assert function_exported?(PlugSample.Worker, :start_link, 1)
    end

    test "has run_demo/0 defined" do
      assert function_exported?(PlugSample.Worker, :run_demo, 0)
    end
  end
end
