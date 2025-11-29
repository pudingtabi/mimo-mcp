defmodule Mimo.Skills.Browser do
  @moduledoc """
  Browser - Real browser automation using Puppeteer with stealth mode.

  This module runs a REAL browser (Chromium) that executes JavaScript.
  Use this when you need to:
  - Solve JavaScript challenges (Cloudflare Turnstile, CAPTCHA)
  - Interact with JS-heavy web applications
  - Take screenshots or generate PDFs
  - Perform UI testing and automation
  - Fill forms and click buttons

  ## When to use Browser vs Blink vs Fetch

  | Tool    | Speed   | JS Execution | Use Case                              |
  |---------|---------|--------------|---------------------------------------|
  | fetch   | Fast    | No           | Simple APIs, static pages             |
  | blink   | Medium  | No           | Sites with basic bot detection        |
  | browser | Slow    | Yes          | JS challenges, CAPTCHA, UI testing    |

  ## Architecture

  Uses Node.js subprocess running Puppeteer with stealth plugins.
  The smart `fetch/2` function tries Blink first (faster), then
  escalates to full browser if a JS challenge is detected.

  ## Operations

  - `fetch` - Load page with full JS execution
  - `screenshot` - Capture page as PNG/JPEG image
  - `pdf` - Generate PDF document from page
  - `evaluate` - Execute custom JavaScript on page
  - `interact` - Perform UI actions (click, type, scroll, etc.)
  - `test` - Run UI test sequences with assertions
  """

  require Logger

  alias Mimo.Skills.Blink

  @default_timeout 60_000
  @node_timeout 90_000

  # Get the script path at runtime
  defp script_path do
    # Try multiple locations
    paths = [
      # Development: relative to project root
      Path.expand("bin/browser-stealth.js", File.cwd!()),
      # Installed: in priv directory
      Path.join(:code.priv_dir(:mimo_mcp) |> to_string(), "browser-stealth.js"),
      # Backup: alongside the compiled code
      Path.join(Path.dirname(__ENV__.file), "../../priv/browser-stealth.js") |> Path.expand()
    ]

    Enum.find(paths, &File.exists?/1) || List.first(paths)
  end

  # Check if Puppeteer is available
  defp puppeteer_available? do
    case System.find_executable("node") do
      nil ->
        false

      _path ->
        script = script_path()
        File.exists?(script)
    end
  end

  @doc """
  Smart fetch that chooses the best method based on the target.

  Tries Blink first for speed, falls back to full browser if challenged.

  ## Options

  - `:force_browser` - Skip Blink and use browser directly (default: false)
  - `:profile` - Browser profile: "chrome", "firefox", "safari", "mobile"
  - `:timeout` - Request timeout in ms (default: 60000)
  - `:wait_for_selector` - Wait for specific element
  - `:cookies` - List of cookies to set
  - `:headers` - Additional headers

  ## Returns

  - `{:ok, %{status: int, body: binary, ...}}`
  - `{:error, reason}`
  """
  def fetch(url, opts \\ []) do
    force_browser = Keyword.get(opts, :force_browser, false)

    if force_browser or not blink_sufficient?(url) do
      browser_fetch(url, opts)
    else
      # Try Blink first
      case Blink.smart_fetch(url, 2, browser: :chrome_136) do
        {:ok, response} ->
          # Check if we got a challenge page
          if is_challenge_response?(response) do
            Logger.info("[Browser] Blink got challenge, escalating to full browser")
            browser_fetch(url, opts)
          else
            {:ok, normalize_blink_response(response)}
          end

        {:challenge, _info} ->
          Logger.info("[Browser] Blink detected challenge, using full browser")
          browser_fetch(url, opts)

        {:blocked, _info} ->
          Logger.info("[Browser] Blink was blocked, trying full browser")
          browser_fetch(url, opts)

        {:error, _reason} ->
          browser_fetch(url, opts)
      end
    end
  end

  @doc """
  Fetch URL using full browser with Puppeteer.
  """
  def browser_fetch(url, opts \\ []) do
    if not puppeteer_available?() do
      {:error,
       "Puppeteer not available. Install with: npm install puppeteer puppeteer-extra puppeteer-extra-plugin-stealth"}
    else
      options = %{
        url: url,
        profile: Keyword.get(opts, :profile, "chrome"),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        waitForSelector: Keyword.get(opts, :wait_for_selector),
        waitForNavigation: Keyword.get(opts, :wait_for_navigation, true),
        waitForChallenge: Keyword.get(opts, :wait_for_challenge, true),
        cookies: Keyword.get(opts, :cookies, []),
        headers: Keyword.get(opts, :headers, %{})
      }

      execute_command("fetch", options)
    end
  end

  @doc """
  Take a screenshot of a page.

  ## Options

  - `:profile` - Browser profile
  - `:full_page` - Capture full page (default: true)
  - `:type` - Image type: "png" or "jpeg" (default: "png")
  - `:quality` - JPEG quality 0-100 (default: 80)
  - `:selector` - Screenshot specific element
  - `:wait_for_selector` - Wait for element before screenshot
  """
  def screenshot(url, opts \\ []) do
    if not puppeteer_available?() do
      {:error, "Puppeteer not available"}
    else
      options = %{
        url: url,
        profile: Keyword.get(opts, :profile, "chrome"),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        fullPage: Keyword.get(opts, :full_page, true),
        type: Keyword.get(opts, :type, "png"),
        quality: Keyword.get(opts, :quality, 80),
        selector: Keyword.get(opts, :selector),
        waitForSelector: Keyword.get(opts, :wait_for_selector)
      }

      execute_command("screenshot", options)
    end
  end

  @doc """
  Generate PDF from a page.

  ## Options

  - `:profile` - Browser profile
  - `:format` - Page format: "A4", "Letter", etc. (default: "A4")
  - `:print_background` - Include background (default: true)
  - `:margin` - Page margins map
  """
  def pdf(url, opts \\ []) do
    if not puppeteer_available?() do
      {:error, "Puppeteer not available"}
    else
      options = %{
        url: url,
        profile: Keyword.get(opts, :profile, "chrome"),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        format: Keyword.get(opts, :format, "A4"),
        printBackground: Keyword.get(opts, :print_background, true),
        margin: Keyword.get(opts, :margin, %{top: "1cm", right: "1cm", bottom: "1cm", left: "1cm"})
      }

      execute_command("pdf", options)
    end
  end

  @doc """
  Execute JavaScript on a page and return the result.

  ## Options

  - `:script` - JavaScript code to execute (required)
  - `:wait_for_selector` - Wait for element before executing
  """
  def evaluate(url, script, opts \\ []) do
    if not puppeteer_available?() do
      {:error, "Puppeteer not available"}
    else
      options = %{
        url: url,
        script: script,
        profile: Keyword.get(opts, :profile, "chrome"),
        timeout: Keyword.get(opts, :timeout, @default_timeout),
        waitForSelector: Keyword.get(opts, :wait_for_selector)
      }

      execute_command("evaluate", options)
    end
  end

  @doc """
  Perform UI interactions on a page.

  ## Actions

  Each action is a map with `:type` and action-specific fields:

  - `%{type: "click", selector: "..."}` - Click element
  - `%{type: "type", selector: "...", text: "..."}` - Type text
  - `%{type: "select", selector: "...", value: "..."}` - Select option
  - `%{type: "wait", selector: "..."}` or `%{type: "wait", ms: 1000}` - Wait
  - `%{type: "scroll", x: 0, y: 500}` - Scroll page
  - `%{type: "hover", selector: "..."}` - Hover over element
  - `%{type: "focus", selector: "..."}` - Focus element
  - `%{type: "press", key: "Enter"}` - Press key
  - `%{type: "screenshot"}` - Take screenshot during interaction
  - `%{type: "evaluate", script: "..."}` - Execute JS
  - `%{type: "waitForNavigation"}` - Wait for page navigation

  ## Example

      Browser.interact("https://example.com", [
        %{type: "type", selector: "#search", text: "hello"},
        %{type: "click", selector: "#submit"},
        %{type: "waitForNavigation"}
      ])
  """
  def interact(url, actions, opts \\ []) do
    if not puppeteer_available?() do
      {:error, "Puppeteer not available"}
    else
      options = %{
        url: url,
        actions: actions,
        profile: Keyword.get(opts, :profile, "chrome"),
        timeout: Keyword.get(opts, :timeout, @default_timeout)
      }

      execute_command("interact", options)
    end
  end

  @doc """
  Run UI test sequence.

  ## Test Format

  Each test is a map with:
  - `:name` - Test name
  - `:actions` - List of actions to perform before assertions (optional)
  - `:assertions` - List of assertions to check

  ## Assertion Types

  - `%{type: "exists", selector: "..."}` - Element exists
  - `%{type: "text", selector: "...", contains: "..."}` - Text content
  - `%{type: "value", selector: "...", expected: "..."}` - Input value
  - `%{type: "visible", selector: "..."}` - Element is visible
  - `%{type: "url", contains: "..."}` - Current URL
  - `%{type: "title", contains: "..."}` - Page title
  - `%{type: "count", selector: "...", expected: 5}` - Element count

  ## Example

      Browser.test("https://example.com", [
        %{
          name: "Homepage loads correctly",
          assertions: [
            %{type: "title", contains: "Example"},
            %{type: "exists", selector: "nav"},
            %{type: "visible", selector: "#main-content"}
          ]
        },
        %{
          name: "Search works",
          actions: [
            %{type: "type", selector: "#search", text: "test"},
            %{type: "click", selector: "#submit"}
          ],
          assertions: [
            %{type: "url", contains: "search"},
            %{type: "count", selector: ".result", expected: 10}
          ]
        }
      ])
  """
  def test(url, tests, opts \\ []) do
    if not puppeteer_available?() do
      {:error, "Puppeteer not available"}
    else
      options = %{
        url: url,
        tests: tests,
        profile: Keyword.get(opts, :profile, "chrome"),
        timeout: Keyword.get(opts, :timeout, @default_timeout)
      }

      execute_command("test", options)
    end
  end

  @doc """
  Check if Puppeteer/browser automation is available.
  """
  def available? do
    puppeteer_available?()
  end

  @doc """
  Analyze a URL to determine the best fetch strategy.
  """
  def analyze(url) do
    case Blink.analyze_protection(url) do
      {:ok, analysis} ->
        needs_browser =
          analysis.challenge_type in [:browser_check, :captcha] or
            analysis.protection in [:cloudflare, :akamai, :datadome]

        {:ok,
         Map.merge(analysis, %{
           recommended_method: if(needs_browser, do: :browser, else: :blink),
           puppeteer_available: puppeteer_available?()
         })}

      error ->
        error
    end
  end

  # Private functions

  defp execute_command(command, options) do
    script = script_path()
    options_json = Jason.encode!(options)

    Logger.debug("[Browser] Executing #{command} with options: #{inspect(options)}")

    # Use Task with timeout instead of System.cmd timeout (which isn't supported)
    task =
      Task.async(fn ->
        System.cmd("node", [script, command, options_json], stderr_to_stdout: true)
      end)

    case Task.yield(task, @node_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        case Jason.decode(output) do
          {:ok, %{"success" => true, "data" => data}} ->
            {:ok, atomize_keys(data)}

          {:ok, %{"success" => false, "error" => error}} ->
            {:error, error}

          {:error, _} ->
            {:error, "Failed to parse browser output: #{output}"}
        end

      {:ok, {output, code}} ->
        Logger.error("[Browser] Command failed with code #{code}: #{output}")
        {:error, "Browser command failed: #{output}"}

      nil ->
        {:error, "Browser operation timed out after #{@node_timeout}ms"}
    end
  rescue
    e ->
      {:error, "Browser error: #{Exception.message(e)}"}
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_atom(k), else: k
      {key, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value

  defp blink_sufficient?(url) do
    # Sites known to require full browser
    challenge_domains = [
      "ticketmaster.com",
      "nowsecure.nl",
      "datadome.co",
      "queue-it.net"
    ]

    uri = URI.parse(url)
    host = uri.host || ""

    not Enum.any?(challenge_domains, &String.contains?(host, &1))
  end

  defp is_challenge_response?(%{body: body, status: status}) when is_binary(body) do
    challenge_patterns = [
      "just a moment",
      "checking your browser",
      "cf-browser-verification",
      "turnstile",
      "please wait",
      "verify you are human",
      "__cf_chl"
    ]

    cond do
      status in [403, 429, 503, 520, 521, 522, 523, 524] -> true
      Enum.any?(challenge_patterns, &String.contains?(String.downcase(body), &1)) -> true
      true -> false
    end
  end

  defp is_challenge_response?(_), do: false

  defp normalize_blink_response(response) do
    %{
      status: response.status,
      body: response.body,
      headers: response.headers,
      method: :blink,
      layer: response[:layer_used] || 0,
      bodySize: byte_size(response.body || "")
    }
  end
end
