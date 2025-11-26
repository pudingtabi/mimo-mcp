defmodule Mix.Tasks.Mimo.KeysTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Mimo.Keys.Generate
  alias Mix.Tasks.Mimo.Keys.Verify
  alias Mix.Tasks.Mimo.Keys.Hash

  @moduletag :mix_task

  describe "Mix.Tasks.Mimo.Keys.Generate" do
    test "generates a key with correct length" do
      {:ok, key} = Generate.run(["--env", "test", "--stdout-only"])

      # Default is 32 bytes, base64 encoded = ~43 chars
      assert byte_size(key) >= 40
    end

    test "generates different keys each time" do
      {:ok, key1} = Generate.run(["--env", "test", "--stdout-only"])
      {:ok, key2} = Generate.run(["--env", "test", "--stdout-only"])

      refute key1 == key2
    end

    test "respects custom key length" do
      {:ok, key} = Generate.run(["--env", "test", "--stdout-only", "--length", "64"])

      # 64 bytes base64 encoded = ~86 chars
      assert byte_size(key) >= 80
    end

    test "rejects key length less than 16 bytes" do
      assert_raise Mix.Error, ~r/at least 16 bytes/, fn ->
        Generate.run(["--env", "test", "--stdout-only", "--length", "8"])
      end
    end

    test "requires --env option" do
      assert_raise Mix.Error, ~r/--env is required/, fn ->
        Generate.run(["--stdout-only"])
      end
    end

    test "validates env is dev, test, or prod" do
      assert_raise Mix.Error, ~r/must be one of/, fn ->
        Generate.run(["--env", "staging", "--stdout-only"])
      end
    end
  end

  describe "Mix.Tasks.Mimo.Keys.Verify" do
    test "reports error when no key configured" do
      # Temporarily clear the API key
      original = Application.get_env(:mimo_mcp, :api_key)
      Application.put_env(:mimo_mcp, :api_key, nil)

      try do
        result = Verify.run(["--env", "test"])
        assert {:error, _} = result
      after
        Application.put_env(:mimo_mcp, :api_key, original)
      end
    end

    test "reports error when key is empty" do
      original = Application.get_env(:mimo_mcp, :api_key)
      Application.put_env(:mimo_mcp, :api_key, "")

      try do
        result = Verify.run(["--env", "test"])
        assert {:error, _} = result
      after
        Application.put_env(:mimo_mcp, :api_key, original)
      end
    end

    test "reports error when key is too short" do
      original = Application.get_env(:mimo_mcp, :api_key)
      Application.put_env(:mimo_mcp, :api_key, "short-key")

      try do
        result = Verify.run(["--env", "test"])
        assert {:error, _} = result
      after
        Application.put_env(:mimo_mcp, :api_key, original)
      end
    end

    test "passes with valid key" do
      original = Application.get_env(:mimo_mcp, :api_key)
      # Generate a valid 32+ byte key
      valid_key = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      Application.put_env(:mimo_mcp, :api_key, valid_key)

      try do
        result = Verify.run(["--env", "test"])
        assert :ok = result
      after
        Application.put_env(:mimo_mcp, :api_key, original)
      end
    end
  end

  describe "Mix.Tasks.Mimo.Keys.Hash" do
    test "generates consistent hash for same key" do
      original = Application.get_env(:mimo_mcp, :api_key)
      test_key = "test-api-key-for-hashing-purposes"
      Application.put_env(:mimo_mcp, :api_key, test_key)

      try do
        {:ok, hash1} = Hash.run([])
        {:ok, hash2} = Hash.run([])

        assert hash1 == hash2
      after
        Application.put_env(:mimo_mcp, :api_key, original)
      end
    end

    test "generates different hash for different keys" do
      {:ok, hash1} = Hash.run(["--key", "key-one-for-testing"])
      {:ok, hash2} = Hash.run(["--key", "key-two-for-testing"])

      refute hash1 == hash2
    end

    test "hash is 16 characters (truncated SHA256)" do
      {:ok, hash} = Hash.run(["--key", "any-key-value"])

      assert String.length(hash) == 16
    end

    test "hash contains only hex characters" do
      {:ok, hash} = Hash.run(["--key", "test-key"])

      assert Regex.match?(~r/^[0-9a-f]+$/, hash)
    end

    test "reports error when no key provided or configured" do
      original = Application.get_env(:mimo_mcp, :api_key)
      Application.put_env(:mimo_mcp, :api_key, nil)

      try do
        result = Hash.run([])
        assert {:error, :no_key} = result
      after
        Application.put_env(:mimo_mcp, :api_key, original)
      end
    end
  end
end
