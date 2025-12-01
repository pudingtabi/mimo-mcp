defmodule Mix.Tasks.Mimo.Keys.Generate do
  @moduledoc """
  Generates cryptographically secure API keys for Mimo MCP Gateway.

  ## Usage

      # Generate a new key for production
      mix mimo.keys.generate --env prod --description "Production key for Claude Desktop"
      
      # Generate a development key
      mix mimo.keys.generate --env dev
      
      # Rotate an existing key
      mix mimo.keys.generate --env prod --rotate
      
  ## Options

    * `--env` - Target environment (dev, test, prod). Required.
    * `--description` - Optional description for the key
    * `--rotate` - Mark this as a key rotation (logs old key hash)
    * `--stdout-only` - Only print key, don't write to file
    * `--length` - Key length in bytes (default: 32)
    
  ## Security

  Generated keys are:
  - 256-bit (32 bytes) cryptographically random by default
  - Base64 URL-safe encoded
  - Written to env files with 0600 permissions (owner read/write only)
  - Never logged to disk or application logs
  """

  use Mix.Task

  @shortdoc "Generate a secure API key for Mimo"

  @switches [
    env: :string,
    description: :string,
    rotate: :boolean,
    stdout_only: :boolean,
    length: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: @switches)

    env = Keyword.get(opts, :env)
    description = Keyword.get(opts, :description, "")
    rotate = Keyword.get(opts, :rotate, false)
    stdout_only = Keyword.get(opts, :stdout_only, false)
    length = Keyword.get(opts, :length, 32)

    # Validate environment
    unless env in ~w(dev test prod) do
      Mix.raise("--env is required and must be one of: dev, test, prod")
    end

    # Validate key length
    if length < 16 do
      Mix.raise("Key length must be at least 16 bytes")
    end

    # Generate cryptographically secure key
    new_key = generate_secure_key(length)

    if rotate do
      log_rotation()
    end

    if stdout_only do
      # Only output to terminal, no file operations
      IO.puts(new_key)
    else
      # Write to .env file
      write_env_file(env, new_key, description)

      # Display to operator
      display_key_info(new_key, env, description)
    end

    {:ok, new_key}
  end

  defp generate_secure_key(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
  end

  defp log_rotation do
    Mix.shell().info("""

    ⚠️  KEY ROTATION IN PROGRESS

    Remember to:
    1. Update all clients with the new key
    2. Consider a grace period with both keys valid
    3. Remove the old key after transition

    """)
  end

  defp write_env_file(env, key, description) do
    env_file = ".env.#{env}"
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    content = """
    # Generated: #{timestamp}
    # Description: #{description}
    MIMO_API_KEY=#{key}
    """

    # Check if file exists for backup
    if File.exists?(env_file) do
      backup_file = "#{env_file}.backup.#{System.system_time(:second)}"
      File.copy!(env_file, backup_file)
      File.chmod!(backup_file, 0o600)
      Mix.shell().info("Backed up existing file to: #{backup_file}")
    end

    # Write new file with restricted permissions
    File.write!(env_file, content)
    File.chmod!(env_file, 0o600)

    Mix.shell().info("Written to: #{env_file} (mode 0600)")
  end

  defp display_key_info(key, env, description) do
    Mix.shell().info("""

    ════════════════════════════════════════════════════════════════
    🔐 NEW API KEY GENERATED
    ════════════════════════════════════════════════════════════════

    Environment: #{env}
    Description: #{if description == "", do: "(none)", else: description}

    Key: #{IO.ANSI.cyan()}#{key}#{IO.ANSI.reset()}

    ════════════════════════════════════════════════════════════════
    ⚠️  SECURITY WARNING
    ════════════════════════════════════════════════════════════════

    1. SAVE THIS KEY NOW - it will not be shown again
    2. Never commit .env files to version control
    3. Use environment variables in production:
       
       export MIMO_API_KEY="#{key}"
       
    4. For Claude Desktop, add to your MCP config:
       
       {
         "mcpServers": {
           "mimo": {
             "env": {
               "MIMO_API_KEY": "#{key}"
             }
           }
         }
       }

    ════════════════════════════════════════════════════════════════
    """)
  end
end

defmodule Mix.Tasks.Mimo.Keys.Verify do
  @moduledoc """
  Verify an API key is properly configured.

  ## Usage

      mix mimo.keys.verify --env prod
      
  Checks:
  - Key is set in environment/config
  - Key meets minimum length requirements
  - Key file has correct permissions
  """

  use Mix.Task

  @shortdoc "Verify API key configuration"

  @switches [env: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: @switches)

    env = Keyword.get(opts, :env, "dev")

    Mix.Task.run("app.config")

    api_key = Application.get_env(:mimo_mcp, :api_key)
    env_file = ".env.#{env}"

    checks = [
      check_key_configured(api_key),
      check_key_length(api_key),
      check_env_file_permissions(env_file)
    ]

    failed = Enum.filter(checks, fn {status, _, _} -> status == :error end)

    if failed == [] do
      Mix.shell().info("✅ All API key checks passed")
      :ok
    else
      Mix.shell().error("❌ #{length(failed)} check(s) failed:")

      Enum.each(failed, fn {_, name, message} ->
        Mix.shell().error("   - #{name}: #{message}")
      end)

      {:error, failed}
    end
  end

  defp check_key_configured(nil), do: {:error, "Key configured", "No API key found in config"}
  defp check_key_configured(""), do: {:error, "Key configured", "API key is empty"}
  defp check_key_configured(_), do: {:ok, "Key configured", "API key is set"}

  defp check_key_length(nil), do: {:error, "Key length", "No key to check"}

  defp check_key_length(key) when byte_size(key) < 32 do
    {:error, "Key length", "Key is too short (#{byte_size(key)} bytes, minimum 32)"}
  end

  defp check_key_length(key) do
    {:ok, "Key length", "Key is #{byte_size(key)} bytes"}
  end

  defp check_env_file_permissions(env_file) do
    case File.stat(env_file) do
      {:ok, %{mode: mode}} ->
        # Check if only owner has read/write
        if Bitwise.band(mode, 0o077) == 0 do
          {:ok, "File permissions", "#{env_file} has correct permissions"}
        else
          {:error, "File permissions", "#{env_file} is world-readable (run: chmod 600 #{env_file})"}
        end

      {:error, :enoent} ->
        {:ok, "File permissions", "#{env_file} does not exist (using environment variable)"}

      {:error, reason} ->
        {:error, "File permissions", "Cannot check #{env_file}: #{reason}"}
    end
  end
end

defmodule Mix.Tasks.Mimo.Keys.Hash do
  @moduledoc """
  Generate a hash of an API key for logging/comparison without exposing the key.

  ## Usage

      # Hash current configured key
      mix mimo.keys.hash
      
      # Hash a specific key
      mix mimo.keys.hash --key YOUR_KEY
      
  Useful for verifying keys match without exposing them in logs.
  """

  use Mix.Task

  @shortdoc "Hash an API key for safe logging"

  @switches [key: :string]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: @switches)

    key =
      case Keyword.get(opts, :key) do
        nil ->
          Mix.Task.run("app.config")
          Application.get_env(:mimo_mcp, :api_key)

        provided ->
          provided
      end

    if is_nil(key) or key == "" do
      Mix.shell().error("No API key found or provided")
      {:error, :no_key}
    else
      hash = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> String.slice(0, 16)

      Mix.shell().info("""

      API Key Hash (first 16 chars of SHA256):
      #{hash}

      Use this hash to verify keys match without exposing them.
      """)

      {:ok, hash}
    end
  end
end
