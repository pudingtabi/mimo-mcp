defmodule Mimo.Skills.Sonar do
  @moduledoc """
  UI accessibility scanner for LLMs.
  Supports Linux (xdotool/wmctrl/atspi) and macOS (AppleScript).
  """
  require Logger

  def scan_ui do
    case detect_environment() do
      :wsl -> {:error, :wsl_not_supported}
      :macos -> scan_macos()
      :linux -> scan_linux()
      :headless -> scan_headless()
      _ -> {:error, :unsupported_platform}
    end
  end

  defp detect_environment do
    wsl_env = System.get_env("WSL_DISTRO_NAME") || System.get_env("WSL_INTEROP")
    display = System.get_env("DISPLAY")
    wayland = System.get_env("WAYLAND_DISPLAY")

    cond do
      is_binary(wsl_env) ->
        :wsl

      wsl_from_proc?() ->
        :wsl

      match?({:unix, :darwin}, :os.type()) ->
        :macos

      match?({:unix, :linux}, :os.type()) and (is_binary(display) or is_binary(wayland)) ->
        :linux

      match?({:unix, :linux}, :os.type()) ->
        :headless

      true ->
        :unsupported
    end
  end

  defp wsl_from_proc? do
    case File.read("/proc/version") do
      {:ok, version} -> String.contains?(String.downcase(version), "microsoft")
      _ -> false
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
      |> Exile.stream!(timeout: 15_000)
      |> Enum.join()
      |> then(&{:ok, &1})
    rescue
      e ->
        Logger.warning("macOS scan failed: #{inspect(e)}")
        {:error, :accessibility_api_error}
    end
  end

  defp scan_linux do
    results = []

    # Try xdotool for active window
    results =
      case get_active_window_xdotool() do
        {:ok, info} -> [{:active_window, info} | results]
        _ -> results
      end

    # Try wmctrl for window list
    results =
      case get_window_list_wmctrl() do
        {:ok, windows} -> [{:window_list, windows} | results]
        _ -> results
      end

    # Try xprop for window properties
    results =
      case get_window_properties() do
        {:ok, props} -> [{:properties, props} | results]
        _ -> results
      end

    # Try AT-SPI if available
    results =
      case get_atspi_tree() do
        {:ok, tree} -> [{:accessibility_tree, tree} | results]
        _ -> results
      end

    if Enum.empty?(results) do
      {:error, :no_display_tools}
    else
      format_linux_results(results)
    end
  end

  defp scan_headless do
    # For headless servers, return process/terminal info instead
    {ps_output, _} = System.cmd("ps", ["aux", "--sort=-pcpu"], stderr_to_stdout: true)
    {who_output, _} = System.cmd("who", [], stderr_to_stdout: true)

    output = """
    Headless Server Scan (no display detected)
    ==========================================

    Active Sessions:
    #{who_output}

    Top Processes:
    #{ps_output |> String.split("\n") |> Enum.take(15) |> Enum.join("\n")}
    """

    {:ok, output}
  end

  defp get_active_window_xdotool do
    if System.find_executable("xdotool") do
      try do
        {win_id, 0} = System.cmd("xdotool", ["getwindowfocus"], stderr_to_stdout: true)
        win_id = String.trim(win_id)
        {title, _} = System.cmd("xdotool", ["getwindowname", win_id], stderr_to_stdout: true)
        {pid, _} = System.cmd("xdotool", ["getwindowpid", win_id], stderr_to_stdout: true)
        {geometry, _} = System.cmd("xdotool", ["getwindowgeometry", win_id], stderr_to_stdout: true)

        {:ok,
         %{
           window_id: win_id,
           title: String.trim(title),
           pid: String.trim(pid),
           geometry: String.trim(geometry)
         }}
      rescue
        _ -> {:error, :xdotool_failed}
      end
    else
      {:error, :xdotool_not_found}
    end
  end

  defp get_window_list_wmctrl do
    if System.find_executable("wmctrl") do
      try do
        {output, 0} = System.cmd("wmctrl", ["-l", "-p"], stderr_to_stdout: true)

        windows =
          output
          |> String.split("\n")
          |> Enum.filter(&(String.trim(&1) != ""))
          |> Enum.map(fn line ->
            case String.split(line, ~r/\s+/, parts: 5) do
              [id, desktop, pid, host | rest] ->
                %{id: id, desktop: desktop, pid: pid, host: host, title: Enum.join(rest, " ")}

              _ ->
                %{raw: line}
            end
          end)

        {:ok, windows}
      rescue
        _ -> {:error, :wmctrl_failed}
      end
    else
      {:error, :wmctrl_not_found}
    end
  end

  defp get_window_properties do
    if System.find_executable("xprop") and System.find_executable("xdotool") do
      try do
        {win_id, 0} = System.cmd("xdotool", ["getwindowfocus"], stderr_to_stdout: true)
        {props, _} = System.cmd("xprop", ["-id", String.trim(win_id)], stderr_to_stdout: true)

        # Extract key properties
        relevant =
          props
          |> String.split("\n")
          |> Enum.filter(fn line ->
            String.contains?(line, "WM_CLASS") or
              String.contains?(line, "WM_NAME") or
              String.contains?(line, "_NET_WM_PID") or
              String.contains?(line, "_NET_WM_STATE")
          end)
          |> Enum.join("\n")

        {:ok, relevant}
      rescue
        _ -> {:error, :xprop_failed}
      end
    else
      {:error, :xprop_not_found}
    end
  end

  defp get_atspi_tree do
    # AT-SPI2 provides accessibility tree on Linux
    if System.find_executable("accerciser") or System.find_executable("atspi2-discover") do
      # accerciser is GUI-only, try python-based introspection
      script = """
      import gi
      gi.require_version('Atspi', '2.0')
      from gi.repository import Atspi
      desktop = Atspi.get_desktop(0)
      for i in range(desktop.get_child_count()):
          app = desktop.get_child_at_index(i)
          if app:
              print(f"App: {app.get_name()}")
              try:
                  for j in range(min(5, app.get_child_count())):
                      child = app.get_child_at_index(j)
                      if child:
                          print(f"  - {child.get_role_name()}: {child.get_name()}")
              except: pass
      """

      if System.find_executable("python3") do
        try do
          {output, code} = System.cmd("python3", ["-c", script], stderr_to_stdout: true)
          if code == 0, do: {:ok, output}, else: {:error, :atspi_failed}
        rescue
          _ -> {:error, :atspi_failed}
        end
      else
        {:error, :python_not_found}
      end
    else
      {:error, :atspi_not_available}
    end
  end

  defp format_linux_results(results) do
    output = ["Linux UI Accessibility Scan", String.duplicate("=", 40), ""]

    output =
      case Keyword.get(results, :active_window) do
        nil ->
          output

        info ->
          output ++
            [
              "Active Window:",
              "  ID: #{info.window_id}",
              "  Title: #{info.title}",
              "  PID: #{info.pid}",
              "  #{info.geometry}",
              ""
            ]
      end

    output =
      case Keyword.get(results, :properties) do
        nil -> output
        props -> output ++ ["Window Properties:", props, ""]
      end

    output =
      case Keyword.get(results, :window_list) do
        nil ->
          output

        windows ->
          window_lines =
            Enum.map(windows, fn w ->
              if Map.has_key?(w, :raw) do
                w.raw
              else
                "  [#{w.id}] #{w.title} (PID: #{w.pid})"
              end
            end)

          output ++ ["All Windows:"] ++ window_lines ++ [""]
      end

    output =
      case Keyword.get(results, :accessibility_tree) do
        nil -> output
        tree -> output ++ ["Accessibility Tree (AT-SPI):", tree, ""]
      end

    {:ok, Enum.join(output, "\n")}
  end
end
