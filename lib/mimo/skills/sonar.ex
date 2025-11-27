defmodule Mimo.Skills.Sonar do
  @moduledoc """
  UI accessibility scanner for LLMs.
  """

  def scan_ui do
    case detect_wsl() do
      true ->
        {:error, :wsl_not_supported}

      false ->
        case :os.type() do
          {:unix, :darwin} -> scan_macos()
          {:unix, :linux} -> scan_linux()
          _ -> {:error, :unsupported_platform}
        end
    end
  end

  defp detect_wsl do
    wsl_env = System.get_env("WSL_DISTRO_NAME") || System.get_env("WSL_INTEROP")

    cond do
      is_binary(wsl_env) ->
        true

      true ->
        case File.read("/proc/version") do
          {:ok, version} -> String.contains?(version, "microsoft")
          _ -> false
        end
    end
  end

  defp scan_macos do
    script = ~S"""
    tell application "System Events"
      set proc to first process whose frontmost is true
      set win to front window of proc
      set output to "Application: " & name of proc & "\nWindow: " & name of win & "\n\nUI Elements:\n"
      repeat with elem in entire contents of win
        try
          set elem_class to class of elem as string
          set elem_name to name of elem as string
          if elem_name is not "" and elem_name is not missing value then
            set output to output & "[" & elem_class & "] " & elem_name & linefeed
          end if
        end try
      end repeat
      return output
    end tell
    """

    try do
      ["osascript", "-e", script]
      |> Exile.stream!(to_charlist: true, timeout: 15_000)
      |> Enum.join()
      |> then(&{:ok, &1})
    rescue
      _e in Exile.Exit -> {:error, :accessibility_api_error}
      _ -> {:error, :unknown_error}
    end
  end

  defp scan_linux do
    if System.find_executable("wmctrl") && System.find_executable("xdotool") do
      try do
        {win_id, 0} = System.cmd("xdotool", ["getwindowfocus"])
        {title, 0} = System.cmd("xdotool", ["getwindowfocus", "getwindowname"])
        {window_list, 0} = System.cmd("wmctrl", ["-l"])

        output = """
        Linux UI Scan Results:
        Active Window ID: #{String.trim(win_id)}
        Active Window Title: #{String.trim(title)}

        All Windows:
        #{window_list}
        """

        {:ok, output}
      rescue
        _ -> {:error, :accessibility_api_error}
      end
    else
      {:error, :not_implemented}
    end
  end
end
