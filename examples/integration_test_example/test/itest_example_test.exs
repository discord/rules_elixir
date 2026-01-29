defmodule ItestExampleTest do
  use ExUnit.Case

  @moduledoc """
  Integration test example demonstrating the integration test framework.

  These tests verify that:
  1. Services are started before tests run
  2. Environment variables are properly exported for service endpoints
  """

  describe "environment variables from services" do
    test "ETCD_HOST is set by the integration test framework" do
      # This env var is auto-exported by the integration test framework
      # based on the service definition
      assert System.get_env("ETCD_HOST") == "localhost"
    end

    test "ETCD_PORT is set by the integration test framework" do
      # Port is derived from the service's ports configuration
      assert System.get_env("ETCD_PORT") == "2379"
    end

    test "ETCD_URL is set by the integration test framework" do
      # URL is auto-generated for HTTP services
      assert System.get_env("ETCD_URL") == "http://localhost:2379"
    end
  end

  describe "user-defined environment variables" do
    test "custom env vars from BUILD.bazel are available" do
      # The BUILD.bazel specifies env = {"ETCD_URL": "http://localhost:2379"}
      # which should be available in addition to auto-generated vars
      url = System.get_env("ETCD_URL")
      assert url != nil
      assert String.starts_with?(url, "http://")
    end
  end
end
