defmodule Mimo.Verification.ActionVerifier do
  @moduledoc """
  SPEC-2026-001: Agent Verification Layer

  Detects "phantom success" - when actions report success but nothing actually changed.

  ## Verification Tiers

  - Light: Check if file actually changed (diff)
  - Medium: Light + compile check
  - Deep: Medium + functional test (optional)

  ## Usage

      # Capture before state
      before = ActionVerifier.capture_state(:file_edit, path)

      # Perform action
      result = FileOps.edit(path, old, new)

      # Verify actual change
      {:verified, details} = ActionVerifier.verify(:file_edit, path, before, result)
  """

  require Logger

  @doc """
  Capture state before an action for later verification.
  """
  def capture_state(:file_edit, path) do
    case File.read(path) do
      {:ok, content} ->
        %{
          type: :file_edit,
          path: path,
          content_hash: :erlang.phash2(content),
          content_length: byte_size(content),
          timestamp: System.monotonic_time(:millisecond)
        }

      {:error, :enoent} ->
        %{
          type: :file_edit,
          path: path,
          content_hash: nil,
          content_length: 0,
          exists: false,
          timestamp: System.monotonic_time(:millisecond)
        }

      {:error, reason} ->
        %{
          type: :file_edit,
          path: path,
          error: reason,
          timestamp: System.monotonic_time(:millisecond)
        }
    end
  end

  def capture_state(:terminal, _command) do
    %{
      type: :terminal,
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  def capture_state(type, _context) do
    %{
      type: type,
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Verify that an action actually produced the expected change.

  Returns:
  - `{:verified, details}` - Action verified, change confirmed
  - `{:phantom_success, details}` - Action "succeeded" but nothing changed
  - `{:verification_error, reason}` - Could not verify
  """
  def verify(:file_edit, path, before_state, action_result) do
    case action_result do
      {:ok, _} ->
        verify_file_change(path, before_state)

      # Handle bare :ok (some operations return just :ok instead of {:ok, result})
      :ok ->
        verify_file_change(path, before_state)

      {:error, reason} ->
        {:verified, %{outcome: :action_failed, reason: reason}}
    end
  end

  def verify(:terminal, _command, _before_state, action_result) do
    case action_result do
      {:ok, output} ->
        verify_terminal_output(output)

      {:error, reason} ->
        {:verified, %{outcome: :action_failed, reason: reason}}
    end
  end

  def verify(_type, _path, _before_state, {:ok, _}) do
    {:verified,
     %{outcome: :unverifiable, note: "Verification not implemented for this action type"}}
  end

  def verify(_type, _path, _before_state, {:error, reason}) do
    {:verified, %{outcome: :action_failed, reason: reason}}
  end

  # Verify file actually changed
  defp verify_file_change(path, before_state) do
    case File.read(path) do
      {:ok, content} ->
        after_hash = :erlang.phash2(content)
        before_hash = Map.get(before_state, :content_hash)
        file_existed = Map.get(before_state, :exists, true)

        cond do
          # File was created (didn't exist before)
          not file_existed and before_hash == nil ->
            {:verified,
             %{
               outcome: :file_created,
               path: path,
               new_length: byte_size(content)
             }}

          # Content actually changed
          after_hash != before_hash ->
            {:verified,
             %{
               outcome: :change_confirmed,
               path: path,
               before_hash: before_hash,
               after_hash: after_hash,
               size_delta: byte_size(content) - Map.get(before_state, :content_length, 0)
             }}

          # PHANTOM SUCCESS: Hash is same, nothing changed!
          true ->
            Logger.warning("[ActionVerifier] Phantom success detected: #{path} unchanged")

            {:phantom_success,
             %{
               outcome: :no_change,
               path: path,
               hash: after_hash,
               warning: "Action reported success but file content is unchanged"
             }}
        end

      {:error, :enoent} ->
        # File doesn't exist after operation
        if Map.get(before_state, :exists, true) do
          # File was deleted
          {:verified, %{outcome: :file_deleted, path: path}}
        else
          # File still doesn't exist
          {:phantom_success,
           %{
             outcome: :no_change,
             path: path,
             warning: "Action reported success but file was not created"
           }}
        end

      {:error, reason} ->
        {:verification_error, %{reason: reason, path: path}}
    end
  end

  # Verify terminal command produced expected output
  defp verify_terminal_output(%{exit_code: 0} = output) do
    {:verified,
     %{
       outcome: :command_succeeded,
       exit_code: 0,
       has_output: byte_size(Map.get(output, :stdout, "")) > 0
     }}
  end

  defp verify_terminal_output(%{exit_code: code} = output) when code != 0 do
    {:verified,
     %{
       outcome: :command_failed,
       exit_code: code,
       stderr: Map.get(output, :stderr, "")
     }}
  end

  defp verify_terminal_output(output) do
    {:verified,
     %{
       outcome: :unverifiable,
       note: "Terminal output format not recognized",
       output: output
     }}
  end

  @doc """
  Tiered verification for code changes.

  - :light - Just check if file changed (fast)
  - :medium - Light + compile check
  - :deep - Medium + run affected tests
  """
  def verify_tiered(path, before_state, result, tier \\ :light) do
    with {:verified, light_details} <- verify(:file_edit, path, before_state, result) do
      case tier do
        :light ->
          {:verified, Map.put(light_details, :tier, :light)}

        :medium ->
          medium_details = add_compile_check(path, light_details)
          {:verified, Map.put(medium_details, :tier, :medium)}

        :deep ->
          medium_details = add_compile_check(path, light_details)
          deep_details = add_test_check(path, medium_details)
          {:verified, Map.put(deep_details, :tier, :deep)}
      end
    end
  end

  # Add compile check for Elixir/Erlang files
  defp add_compile_check(path, details) do
    if Path.extname(path) in [".ex", ".exs"] do
      case System.cmd("mix", ["compile", "--warnings-as-errors"], stderr_to_stdout: true) do
        {_, 0} ->
          Map.put(details, :compile_check, :passed)

        {output, _} ->
          Map.merge(details, %{
            compile_check: :failed,
            compile_errors: String.slice(output, 0, 500)
          })
      end
    else
      Map.put(details, :compile_check, :skipped)
    end
  end

  # Add test check (placeholder for deep tier)
  defp add_test_check(_path, details) do
    # In production, this would run affected tests
    Map.put(details, :test_check, :not_implemented)
  end
end
