defmodule Mimo.Skills.Blink do
  @moduledoc """
  Blink - Enhanced Web Retrieval Module

  Provides robust web content retrieval with realistic browser characteristics.
  Handles various web environments that may require specific client configurations.

  ## Features

  1. **Browser Profiles** - Uses realistic client configurations
  2. **Response Analysis** - Identifies response characteristics
  3. **Adaptive Requests** - Adjusts approach based on responses
  4. **Multi-Layer Strategy** - Progressive configuration levels

  ## Configuration Layers

  Layer 0: Standard request with common headers
  Layer 1: Enhanced client configuration (headers, ordering)
  Layer 2: Advanced TLS settings (cipher suites, extensions)
  """

  require Logger

  # Browser client profiles
  @browser_profiles %{
    chrome_136: %{
      user_agent:
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
      sec_ch_ua: "\"Chromium\";v=\"136\", \"Google Chrome\";v=\"136\", \"Not.A/Brand\";v=\"99\"",
      sec_ch_ua_mobile: "?0",
      sec_ch_ua_platform: "\"Windows\"",
      accept:
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
      accept_language: "en-US,en;q=0.9",
      accept_encoding: "gzip, deflate, br, zstd",
      upgrade_insecure_requests: "1",
      header_order: [
        "host",
        "connection",
        "cache-control",
        "sec-ch-ua",
        "sec-ch-ua-mobile",
        "sec-ch-ua-platform",
        "upgrade-insecure-requests",
        "user-agent",
        "accept",
        "sec-fetch-site",
        "sec-fetch-mode",
        "sec-fetch-user",
        "sec-fetch-dest",
        "accept-encoding",
        "accept-language"
      ],
      tls_config: %{
        versions: [:"tlsv1.3", :"tlsv1.2"],
        ciphers: [
          "TLS_AES_128_GCM_SHA256",
          "TLS_AES_256_GCM_SHA384",
          "TLS_CHACHA20_POLY1305_SHA256",
          "ECDHE-ECDSA-AES128-GCM-SHA256",
          "ECDHE-RSA-AES128-GCM-SHA256",
          "ECDHE-ECDSA-AES256-GCM-SHA384",
          "ECDHE-RSA-AES256-GCM-SHA384"
        ],
        alpn: ["h2", "http/1.1"]
      }
    },
    firefox_135: %{
      user_agent:
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:135.0) Gecko/20100101 Firefox/135.0",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      accept_language: "en-US,en;q=0.5",
      accept_encoding: "gzip, deflate, br, zstd",
      upgrade_insecure_requests: "1",
      header_order: [
        "host",
        "user-agent",
        "accept",
        "accept-language",
        "accept-encoding",
        "connection",
        "upgrade-insecure-requests",
        "sec-fetch-dest",
        "sec-fetch-mode",
        "sec-fetch-site"
      ],
      tls_config: %{
        versions: [:"tlsv1.3", :"tlsv1.2"],
        ciphers: [
          "TLS_AES_128_GCM_SHA256",
          "TLS_CHACHA20_POLY1305_SHA256",
          "TLS_AES_256_GCM_SHA384",
          "ECDHE-ECDSA-AES128-GCM-SHA256",
          "ECDHE-RSA-AES128-GCM-SHA256"
        ],
        alpn: ["h2", "http/1.1"]
      }
    },
    safari_18: %{
      user_agent:
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      accept_language: "en-US,en;q=0.9",
      accept_encoding: "gzip, deflate, br",
      upgrade_insecure_requests: "1",
      header_order: [
        "host",
        "accept",
        "sec-fetch-site",
        "sec-fetch-dest",
        "sec-fetch-mode",
        "user-agent",
        "accept-language",
        "accept-encoding",
        "connection"
      ],
      tls_config: %{
        versions: [:"tlsv1.3", :"tlsv1.2"],
        ciphers: [
          "TLS_AES_128_GCM_SHA256",
          "TLS_AES_256_GCM_SHA384",
          "TLS_CHACHA20_POLY1305_SHA256",
          "ECDHE-ECDSA-AES256-GCM-SHA384",
          "ECDHE-ECDSA-AES128-GCM-SHA256"
        ],
        alpn: ["h2", "http/1.1"]
      }
    }
  }

  # Response characteristic patterns
  @protection_patterns %{
    cloudflare: %{
      challenge_titles: [
        "Just a moment...",
        "Checking your browser before accessing",
        "Attention Required!"
      ],
      challenge_indicators: [
        "cf-browser-verification",
        "cf_chl_opt",
        "cf-spinner",
        "__cf_chl_tk"
      ],
      headers: ["cf-ray", "cf-cache-status"],
      cookie_names: ["__cf_bm", "cf_clearance"]
    },
    akamai: %{
      challenge_indicators: ["ak_bmsc", "_abck"],
      headers: ["x-akamai-transformed"]
    },
    datadome: %{
      challenge_indicators: ["datadome", "dd_c"],
      headers: ["x-datadome"]
    }
  }

  # Helper to get browser profile with fallback
  defp get_profile(browser) do
    case Map.get(@browser_profiles, browser) do
      nil ->
        Logger.debug("[Blink] Unknown browser profile #{inspect(browser)}, using chrome_136")
        Map.get(@browser_profiles, :chrome_136)

      profile ->
        profile
    end
  end

  @doc """
  Smart fetch with automatic response handling and adaptive retries.

  ## Options

  - `:browser` - Browser profile to use (:chrome_136, :firefox_135, :safari_18)
  - `:max_retries` - Maximum retry attempts (default: 3)
  - `:layer` - Maximum technique layer to use (0-2, default: 2)

  ## Returns

  - `{:ok, %{status: int, body: binary, headers: map, layer_used: int}}`
  - `{:error, reason}`
  - `{:challenge, %{type: atom, details: map}}`
  """
  def fetch(url, opts \\ []) do
    browser = Keyword.get(opts, :browser, :chrome_136)
    max_retries = Keyword.get(opts, :max_retries, 3)
    max_layer = Keyword.get(opts, :layer, 2)

    Logger.debug("[Blink] Fetching #{url} with browser=#{browser}")

    do_fetch_with_layers(url, browser, max_retries, max_layer, 0)
  end

  @doc """
  Analyze response characteristics of a URL.
  """
  def detect_protection(url) when is_binary(url) do
    case basic_fetch(url, :chrome_136) do
      {:ok, response} -> analyze_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  def detect_protection(%{status: _status, body: _body, headers: _headers} = response) do
    analyze_response(response)
  end

  @doc """
  Check if a response indicates a challenge or block.
  """
  def challenged?(%{status: status, body: body}) do
    cond do
      status == 403 -> {:blocked, :forbidden}
      status == 429 -> {:blocked, :rate_limited}
      status in [503, 520, 521, 522, 523, 524] -> {:challenge, :service_challenge}
      contains_challenge_page?(body) -> {:challenge, :browser_check}
      true -> false
    end
  end

  def challenged?(_), do: false

  @doc """
  Get available browser profiles.
  """
  def browser_profiles, do: Map.keys(@browser_profiles)

  # Private implementation

  defp do_fetch_with_layers(url, browser, retries_left, max_layer, current_layer)
       when retries_left > 0 do
    result = fetch_by_layer(url, browser, current_layer)

    case handle_fetch_result(result, url, browser, retries_left, max_layer, current_layer) do
      {:escalate, next_layer} ->
        Process.sleep(jittered_delay(1000))
        do_fetch_with_layers(url, browser, retries_left, max_layer, next_layer)

      {:retry_blocked, next_browser} ->
        Process.sleep(jittered_delay(2000))
        do_fetch_with_layers(url, next_browser, retries_left - 1, max_layer, current_layer)

      other ->
        other
    end
  end

  defp do_fetch_with_layers(_url, _browser, 0, _max_layer, _current_layer) do
    {:error, :max_retries_exceeded}
  end

  defp fetch_by_layer(url, browser, 0), do: basic_fetch(url, browser)
  defp fetch_by_layer(url, browser, 1), do: layer_1_fetch(url, browser)
  defp fetch_by_layer(url, browser, 2), do: layer_2_fetch(url, browser)
  defp fetch_by_layer(_url, _browser, _), do: {:error, :max_layer_exceeded}

  defp handle_fetch_result({:ok, response}, _url, browser, retries_left, max_layer, current_layer) do
    handle_challenge_check(
      challenged?(response),
      response,
      browser,
      retries_left,
      current_layer,
      max_layer
    )
  end

  defp handle_fetch_result({:error, _reason}, url, browser, retries_left, max_layer, current_layer)
       when retries_left > 1 do
    Process.sleep(jittered_delay(1000))
    do_fetch_with_layers(url, browser, retries_left - 1, max_layer, current_layer)
  end

  defp handle_fetch_result({:error, reason}, _url, _browser, _retries, _max_layer, _current_layer) do
    {:error, reason}
  end

  defp handle_challenge_check(false, response, _browser, _retries, current_layer, _max_layer) do
    {:ok, Map.put(response, :layer_used, current_layer)}
  end

  defp handle_challenge_check(
         {:challenge, type},
         _response,
         _browser,
         _retries,
         current_layer,
         max_layer
       )
       when current_layer < max_layer do
    Logger.info("[Blink] Challenge detected (#{type}), escalating to layer #{current_layer + 1}")
    {:escalate, current_layer + 1}
  end

  defp handle_challenge_check(
         {:challenge, type},
         response,
         _browser,
         _retries,
         current_layer,
         _max_layer
       ) do
    {:challenge, %{type: type, response: response, layer: current_layer}}
  end

  defp handle_challenge_check(
         {:blocked, _reason},
         _response,
         browser,
         retries_left,
         _current_layer,
         _max_layer
       )
       when retries_left > 1 do
    {:retry_blocked, rotate_browser(browser)}
  end

  defp handle_challenge_check(
         {:blocked, reason},
         response,
         _browser,
         _retries,
         _current_layer,
         _max_layer
       ) do
    {:blocked, %{reason: reason, response: response}}
  end

  defp basic_fetch(url, browser) do
    profile = get_profile(browser)
    headers = build_basic_headers(profile)

    case Req.get(url,
           headers: headers,
           redirect: true,
           max_redirects: 5,
           receive_timeout: 30_000,
           retry: false,
           raw: true
         ) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        headers_map = Map.new(resp_headers)
        decompressed_body = decompress_body(body, headers_map)
        {:ok, %{status: status, body: decompressed_body, headers: headers_map}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp layer_1_fetch(url, browser) do
    profile = get_profile(browser)
    headers = build_ordered_headers(profile, url)

    case Req.get(url,
           headers: headers,
           redirect: true,
           max_redirects: 5,
           receive_timeout: 30_000,
           retry: false,
           raw: true
         ) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        headers_map = Map.new(resp_headers)
        decompressed_body = decompress_body(body, headers_map)
        {:ok, %{status: status, body: decompressed_body, headers: headers_map}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp layer_2_fetch(url, browser) do
    profile = get_profile(browser)
    headers = build_ordered_headers(profile, url)
    tls_opts = build_tls_options(profile.tls_config)

    case Req.get(url,
           headers: headers,
           redirect: true,
           max_redirects: 5,
           receive_timeout: 30_000,
           retry: false,
           raw: true,
           connect_options: [transport_opts: tls_opts]
         ) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        headers_map = Map.new(resp_headers)
        decompressed_body = decompress_body(body, headers_map)
        {:ok, %{status: status, body: decompressed_body, headers: headers_map}}

      {:error, _reason} ->
        # Fallback to layer 1 if TLS customization fails
        layer_1_fetch(url, browser)
    end
  end

  # Decompress body based on content-encoding header
  # Uses direct NIF access for brotli to avoid streaming issues
  defp decompress_body(body, headers) when is_binary(body) do
    encoding = extract_encoding(headers)
    do_decompress(encoding, body)
  end

  defp decompress_body(body, _headers), do: body

  defp extract_encoding(headers) do
    case Map.get(headers, "content-encoding", "") do
      [enc | _] -> enc
      enc when is_binary(enc) -> enc
      _ -> ""
    end
  end

  # Brotli decompression using direct NIF
  defp do_decompress("br", body) do
    decoder = :brotli_nif.decoder_create()

    case :brotli_nif.decoder_decompress_stream(decoder, body) do
      :ok -> :brotli_nif.decoder_take_output(decoder)
      :more -> :brotli_nif.decoder_take_output(decoder)
      _ -> body
    end
  end

  # Gzip decompression
  defp do_decompress("gzip", body) do
    try do
      :zlib.gunzip(body)
    catch
      _, _ -> body
    end
  end

  # Deflate decompression
  defp do_decompress("deflate", body) do
    try do
      :zlib.uncompress(body)
    catch
      _, _ -> body
    end
  end

  # No compression or unknown encoding
  defp do_decompress(_encoding, body), do: body

  defp build_basic_headers(profile) do
    base = [
      {"user-agent", profile.user_agent},
      {"accept", profile.accept},
      {"accept-language", profile.accept_language},
      {"accept-encoding", profile.accept_encoding},
      {"upgrade-insecure-requests", profile.upgrade_insecure_requests}
    ]

    if Map.has_key?(profile, :sec_ch_ua) do
      base ++
        [
          {"sec-ch-ua", profile.sec_ch_ua},
          {"sec-ch-ua-mobile", profile.sec_ch_ua_mobile},
          {"sec-ch-ua-platform", profile.sec_ch_ua_platform},
          {"sec-fetch-site", "none"},
          {"sec-fetch-mode", "navigate"},
          {"sec-fetch-user", "?1"},
          {"sec-fetch-dest", "document"}
        ]
    else
      base ++
        [
          {"sec-fetch-site", "none"},
          {"sec-fetch-mode", "navigate"},
          {"sec-fetch-dest", "document"}
        ]
    end
  end

  defp build_ordered_headers(profile, url) do
    uri = URI.parse(url)

    all_headers = %{
      "host" => uri.host,
      "connection" => "keep-alive",
      "cache-control" => "max-age=0",
      "user-agent" => profile.user_agent,
      "accept" => profile.accept,
      "accept-language" => profile.accept_language,
      "accept-encoding" => profile.accept_encoding,
      "upgrade-insecure-requests" => profile.upgrade_insecure_requests,
      "sec-fetch-site" => "none",
      "sec-fetch-mode" => "navigate",
      "sec-fetch-user" => "?1",
      "sec-fetch-dest" => "document"
    }

    all_headers =
      if Map.has_key?(profile, :sec_ch_ua) do
        Map.merge(all_headers, %{
          "sec-ch-ua" => profile.sec_ch_ua,
          "sec-ch-ua-mobile" => profile.sec_ch_ua_mobile,
          "sec-ch-ua-platform" => profile.sec_ch_ua_platform
        })
      else
        all_headers
      end

    profile.header_order
    |> Enum.filter(&Map.has_key?(all_headers, &1))
    |> Enum.map(fn key -> {key, Map.get(all_headers, key)} end)
  end

  defp build_tls_options(tls_config) do
    [
      versions: tls_config.versions,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3
    ]
  end

  defp analyze_response(%{status: status, body: body, headers: headers}) do
    header_detection = detect_from_headers(headers)
    body_detection = detect_from_body(body)

    protection = header_detection || body_detection
    challenge_type = determine_challenge_type(status, body)

    %{
      protection: protection,
      challenge_type: challenge_type,
      status: status,
      cdn: detect_cdn(headers)
    }
  end

  defp detect_from_headers(headers) do
    Enum.find_value(@protection_patterns, fn {name, patterns} ->
      header_list = patterns[:headers] || []
      if Enum.any?(header_list, &Map.has_key?(headers, &1)), do: name
    end)
  end

  defp detect_from_body(body) when is_binary(body) do
    body_lower = String.downcase(body)

    Enum.find_value(@protection_patterns, fn {name, patterns} ->
      indicators = (patterns[:challenge_indicators] || []) ++ (patterns[:challenge_titles] || [])
      if Enum.any?(indicators, &String.contains?(body_lower, String.downcase(&1))), do: name
    end)
  end

  defp detect_from_body(_), do: nil

  defp determine_challenge_type(status, body) do
    cond do
      status == 403 -> :blocked
      status == 429 -> :rate_limited
      status in [503, 520, 521, 522, 523, 524] -> :service_challenge
      contains_captcha?(body) -> :captcha
      contains_challenge_page?(body) -> :browser_check
      true -> nil
    end
  end

  defp contains_challenge_page?(body) when is_binary(body) do
    patterns = ["just a moment", "checking your browser", "please wait", "verify you are human"]
    body_lower = String.downcase(body)
    Enum.any?(patterns, &String.contains?(body_lower, &1))
  end

  defp contains_challenge_page?(_), do: false

  defp contains_captcha?(body) when is_binary(body) do
    patterns = ["captcha", "recaptcha", "hcaptcha", "turnstile"]
    body_lower = String.downcase(body)
    Enum.any?(patterns, &String.contains?(body_lower, &1))
  end

  defp contains_captcha?(_), do: false

  defp detect_cdn(headers) do
    cond do
      Map.has_key?(headers, "cf-ray") -> :cloudflare
      Map.has_key?(headers, "x-amz-cf-id") -> :aws_cloudfront
      Map.has_key?(headers, "x-akamai-transformed") -> :akamai
      true -> nil
    end
  end

  defp rotate_browser(current) do
    browsers = [:chrome_136, :firefox_135, :safari_18]
    current_index = Enum.find_index(browsers, &(&1 == current)) || 0
    Enum.at(browsers, rem(current_index + 1, length(browsers)))
  end

  defp jittered_delay(base_ms) do
    jitter = :rand.uniform(div(base_ms, 2))
    base_ms + jitter
  end

  @doc """
  Analyze response characteristics and configuration.
  """
  def analyze_protection(url) do
    Logger.info("[Blink] Analyzing protection for #{url}")

    case basic_fetch(url, :chrome_136) do
      {:ok, response} ->
        detection = analyze_response(response)

        {:ok,
         Map.merge(detection, %{
           cookies: get_cookies(response),
           server: Map.get(response.headers, "server")
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Smart fetch - Automatically escalates through all layers until success.
  This is an alias for fetch with explicit parameters for clarity.

  ## Parameters

  - `url` - URL to fetch
  - `max_retries` - Maximum number of retry attempts (default: 3)
  - `opts` - Options (see fetch/2)

  ## Example

      Blink.smart_fetch("https://protected-site.com", 5, browser: :chrome_136)
  """
  def smart_fetch(url, max_retries \\ 3, opts \\ []) do
    opts = Keyword.put(opts, :max_retries, max_retries)
    # Always use max layer for smart mode
    opts = Keyword.put_new(opts, :layer, 2)
    fetch(url, opts)
  end

  defp get_cookies(%{headers: headers}) do
    case Map.get(headers, "set-cookie") do
      nil -> []
      cookies when is_list(cookies) -> cookies
      cookie when is_binary(cookie) -> [cookie]
    end
  end
end
