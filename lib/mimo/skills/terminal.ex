defmodule Mimo.Skills.Terminal do
  @moduledoc """
  Non-blocking, secure command executor using Exile.
  """

  @default_timeout 30_000
  @restricted_mode true

  @allowed_commands MapSet.new(~w[
    ls cat grep head tail echo git date pwd whoami find wc stat file which
    ps kill pkill pgrep mkdir touch
  ])

  @blocked_commands MapSet.new(~w[
    rm mv cp shred dd chmod chown chgrp chattr
    sh bash zsh csh fish dash tcsh ksh
    sudo su doas pkexec runuser
    curl wget aria2c axel ftp sftp scp tftp
    mysql psql sqlite3 mongo redis-cli psqlodbc
    docker podman kubectl helm minikube
  ])

  @blocked_tui_commands MapSet.new(~w[
    vim nvim nano emacs micro ed ex vi
    top htop bashtop bpytop gotop ytop
    less more most mostty
    screen tmux byobu
    ssh sshd telnet
  ])

  def execute(cmd_str, opts \\ []) when is_binary(cmd_str) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    restricted = Keyword.get(opts, :restricted, @restricted_mode)

    case validate_cmd(cmd_str, restricted) do
      :ok -> execute_safe(cmd_str, timeout)
      {:error, reason} -> %{status: 1, output: "Security error: #{reason}"}
    end
  end

  defp validate_cmd(cmd_str, restricted) do
    parts = String.split(cmd_str)
    base_cmd = List.first(parts)

    cond do
      is_nil(base_cmd) or base_cmd == "" ->
        {:error, "Empty command"}

      MapSet.member?(@blocked_tui_commands, base_cmd) ->
        {:error, "Interactive command '#{base_cmd}' is prohibited"}

      not restricted ->
        :ok

      MapSet.member?(@blocked_commands, base_cmd) ->
        {:error, "Command '#{base_cmd}' is blocked"}

      not MapSet.member?(@allowed_commands, base_cmd) ->
        {:error, "Command '#{base_cmd}' not in allowlist"}

      not sanitize_args(cmd_str) ->
        {:error, "Arguments contain shell meta-characters"}

      true ->
        :ok
    end
  end

  defp sanitize_args(cmd_str) do
    # Reject shell control operators
    not Regex.match?(~r/[;&|`$()<>*?{}\[\]!]/, cmd_str)
  end

  defp execute_safe(cmd_str, timeout) do
    task =
      Task.async(fn ->
        try do
          [cmd | args] = String.split(cmd_str)
          stream = Exile.stream!([cmd | args])

          output =
            Enum.reduce(stream, "", fn
              {:stdout, data}, acc -> acc <> data
              {:stderr, data}, acc -> acc <> data
              _, acc -> acc
            end)

          %{status: 0, output: output}
        rescue
          e -> %{status: 1, output: "Execution error: #{Exception.message(e)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> %{status: 1, output: "Command timed out after #{timeout}ms"}
    end
  end
end
