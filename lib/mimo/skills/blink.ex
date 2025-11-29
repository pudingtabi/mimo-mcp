defmodule Mimo.Skills.Blink do
  @moduledoc """
  Blink - Advanced Web Traversal Skills
  
  Named after the ability to move through barriers instantly, Blink provides
  sophisticated techniques for accessing web content that may be protected by
  various anti-automation systems.
  
  Philosophy:
  "To understand protection, one must understand how it can be traversed.
   This knowledge serves both offense and defense."
  
  ## Capabilities
  
  1. **Browser Fingerprint Impersonation** - Mimics real browser TLS/HTTP signatures
  2. **Challenge Detection** - Identifies protection mechanisms
  3. **Smart Retry Logic** - Adaptive request strategies
  4. **Multi-Layer Approach** - Escalates techniques as needed
  
  ## Ethical Use
  
  This module is designed for:
  - Understanding web security mechanisms
  - Testing your own systems' defenses
  - Legitimate data collection within terms of service
  - Security research and education
  
  ## Technique Layers
  
  Layer 0: Standard request with browser headers
  Layer 1: Enhanced fingerprinting (User-Agent, headers order)
  Layer 2: TLS customization (cipher suites, extensions)
  Layer 3: JavaScript challenge solving (requires headless browser)
  Layer 4: CAPTCHA solving (requires external service or manual intervention)
  
  Currently implements Layers 0-2 natively, with hooks for 3-4.
  """

  require Logger

  # Browser fingerprint profiles - Updated for 2025
  @browser_profiles %{
    chrome_136: %{
      user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
      sec_ch_ua: "\"Chromium\";v=\"136\", \"Google Chrome\";v=\"136\", \"Not.A/Brand\";v=\"99\"",
      sec_ch_ua_mobile: "?0",
      sec_ch_ua_platform: "\"Windows\"",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
      accept_language: "en-US,en;q=0.9",
      accept_encoding: "gzip, deflate, br, zstd",
      upgrade_insecure_requests: "1",
      # Header order matters for fingerprinting
      header_order: [
        "host", "connection", "cache-control", "sec-ch-ua", "sec-ch-ua-mobile",
        "sec-ch-ua-platform", "upgrade-insecure-requests", "user-agent", "accept",
        "sec-fetch-site", "sec-fetch-mode", "sec-fetch-user", "sec-fetch-dest",
        "accept-encoding", "accept-language"
      ],
      # TLS configuration to match Chrome
      tls_config: %{
        versions: [:"tlsv1.3", :"tlsv1.2"],
        ciphers: [
          # TLS 1.3 ciphers (Chrome order)
          "TLS_AES_128_GCM_SHA256",
          "TLS_AES_256_GCM_SHA384",
          "TLS_CHACHA20_POLY1305_SHA256",
          # TLS 1.2 ciphers (Chrome order)
          "ECDHE-ECDSA-AES128-GCM-SHA256",
          "ECDHE-RSA-AES128-GCM-SHA256",
          "ECDHE-ECDSA-AES256-GCM-SHA384",
          "ECDHE-RSA-AES256-GCM-SHA384",
          "ECDHE-ECDSA-CHACHA20-POLY1305",
          "ECDHE-RSA-CHACHA20-POLY1305"
        ],
        signature_algs: [
          :ecdsa_secp256r1_sha256,
          :rsa_pss_rsae_sha256,
          :rsa_pkcs1_sha256,
          :ecdsa_secp384r1_sha384,
          :rsa_pss_rsae_sha384,
          :rsa_pkcs1_sha384,
          :rsa_pss_rsae_sha512,
          :rsa_pkcs1_sha512
        ],
        # ALPN for HTTP/2 support
        alpn: ["h2", "http/1.1"]
      }
    },
    firefox_135: %{
      user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:135.0) Gecko/20100101 Firefox/135.0",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      accept_language: "en-US,en;q=0.5",
      accept_encoding: "gzip, deflate, br, zstd",
      upgrade_insecure_requests: "1",
      header_order: [
        "host", "user-agent", "accept", "accept-language", "accept-encoding",
        "connection", "upgrade-insecure-requests", "sec-fetch-dest", 
        "sec-fetch-mode", "sec-fetch-site"
      ],
      tls_config: %{
        versions: [:"tlsv1.3", :"tlsv1.2"],
        ciphers: [
          # Firefox cipher order
          "TLS_AES_128_GCM_SHA256",
          "TLS_CHACHA20_POLY1305_SHA256",
          "TLS_AES_256_GCM_SHA384",
          "ECDHE-ECDSA-AES128-GCM-SHA256",
          "ECDHE-RSA-AES128-GCM-SHA256",
          "ECDHE-ECDSA-CHACHA20-POLY1305",
          "ECDHE-RSA-CHACHA20-POLY1305",
          "ECDHE-ECDSA-AES256-GCM-SHA384",
          "ECDHE-RSA-AES256-GCM-SHA384"
        ],
        alpn: ["h2", "http/1.1"]
      }
    },
    safari_18: %{
      user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      accept_language: "en-US,en;q=0.9",
      accept_encoding: "gzip, deflate, br",
      header_order: [
        "host", "accept", "sec-fetch-site", "sec-fetch-dest", "sec-fetch-mode",
        "user-agent", "accept-language", "accept-encoding", "connection"
      ],
      tls_config: %{
        versions: [:"tlsv1.3", :"tlsv1.2"],
        ciphers: [
          # Safari cipher order
          "TLS_AES_128_GCM_SHA256",
          "TLS_AES_256_GCM_SHA384",
          "TLS_CHACHA20_POLY1305_SHA256",
          "ECDHE-ECDSA-AES256-GCM-SHA384",
          "ECDHE-ECDSA-AES128-GCM-SHA256",
          "ECDHE-RSA-AES256-GCM-SHA384",
          "ECDHE-RSA-AES128-GCM-SHA256",
          "ECDHE-ECDSA-CHACHA20-POLY1305",
          "ECDHE-RSA-CHACHA20-POLY1305"
        ],
        alpn: ["h2", "http/1.1"]
      }
    }
  }

  # Protection detection patterns
  @protection_patterns %{
    cloudflare: %{
      challenge_titles: [
        "Just a moment...",
        "Checking your browser before accessing",
        "Attention Required! | Cloudflare",
        "Please Wait... | Cloudflare"
      ],
      challenge_indicators: [
        "cf-browser-verification",
        "cf_chl_opt",
        "cf-spinner",
        "__cf_chl_tk",
        "Checking if the site connection is secure"
      ],
      headers: [
        "cf-ray",
        "cf-cache-status",
        "cf-request-id"
      ],
      error_codes: [1020, 1015, 1010, 1009, 1006],
      cookie_names: ["__cf_bm", "cf_clearance", "__cfduid"]
    },
    akamai: %{
      challenge_indicators: [
        "ak_bmsc",
        "_abck",
        "akamai"
      ],
      headers: [
        "x-akamai-transformed",
        "akamai-grn"
      ]
    },
    imperva: %{
      challenge_indicators: [
        "incap_ses",
        "visid_incap",
        "___utmvc"
      ],
      headers: [
        "x-iinfo",
        "x-cdn"
      ]
    },
    datadome: %{
      challenge_indicators: [
        "datadome",
        "dd_c"
      ],
      headers: [
        "x-datadome"
      ]
    },
    perimeter_x: %{
      challenge_indicators: [
        "_px",
        "_pxvid",
        "human challenge"
      ]
    }
  }

  @doc """
  Smart fetch with automatic protection detection and bypass attempts.
  
  ## Options
  
  - `:browser` - Browser profile to use (:chrome_136, :firefox_135, :safari_18)
  - `:max_retries` - Maximum retry attempts (default: 3)
  - `:delay_ms` - Base delay between retries (default: 1000)
  - `:follow_redirects` - Follow redirects (default: true)
  - `:timeout` - Request timeout in ms (default: 30000)
  - `:layer` - Maximum technique layer to use (0-2, default: 2)
  
  ## Returns
  
  - `{:ok, %{status: int, body: binary, headers: map, protection: atom | nil}}`
  - `{:error, reason}`
  - `{:challenge, %{type: atom, details: map}}` - When challenge detected but not solvable
  """
  def fetch(url, opts \\ []) do
    browser = Keyword.get(opts, :browser, :chrome_136)
    max_retries = Keyword.get(opts, :max_retries, 3)
    max_layer = Keyword.get(opts, :layer, 2)
    
    Logger.debug("[Blink] Fetching #{url} with browser=#{browser}, max_layer=#{max_layer}")
    
    do_fetch_with_layers(url, browser, max_retries, max_layer, 0)
  end

  @doc """
  Detect what protection system a site is using.
  
  Returns a map with:
  - `:protection` - The detected protection system or nil
  - `:confidence` - Confidence level (:high, :medium, :low)
  - `:indicators` - List of detected indicators
  - `:challenge_type` - Type of challenge if present (:js, :captcha, :blocked, nil)
  """
  def detect_protection(url_or_response)

  def detect_protection(url) when is_binary(url) do
    case basic_fetch(url, :chrome_136) do
      {:ok, response} -> analyze_response_for_protection(response)
      {:error, reason} -> {:error, reason}
    end
  end

  def detect_protection(%{status: status, body: body, headers: headers}) do
    analyze_response_for_protection(%{status: status, body: body, headers: headers})
  end

  @doc """
  Check if a response indicates a challenge or block.
  """
  def is_challenged?(%{status: status, body: body}) do
    cond do
      status == 403 -> {:blocked, :forbidden}
      status == 429 -> {:blocked, :rate_limited}
      status in [503, 520, 521, 522, 523, 524] -> {:challenge, :service_challenge}
      contains_challenge_page?(body) -> {:challenge, :browser_check}
      true -> false
    end
  end

  def is_challenged?(_), do: false

  @doc """
  Get available browser profiles.
  """
  def browser_profiles, do: Map.keys(@browser_profiles)

  @doc """
  Get details of a specific browser profile.
  """
  def get_profile(browser), do: Map.get(@browser_profiles, browser)

  # Private implementation

  defp do_fetch_with_layers(url, browser, retries_left, max_layer, current_layer) when retries_left > 0 do
    Logger.debug("[Blink] Attempting layer #{current_layer}, retries_left=#{retries_left}")
    
    result = case current_layer do
      0 -> layer_0_fetch(url, browser)
      1 -> layer_1_fetch(url, browser)
      2 -> layer_2_fetch(url, browser)
      _ -> {:error, :max_layer_exceeded}
    end
    
    case result do
      {:ok, response} ->
        case is_challenged?(response) do
          false -> 
            {:ok, Map.put(response, :layer_used, current_layer)}
          
          {:challenge, type} when current_layer < max_layer ->
            Logger.info("[Blink] Challenge detected (#{type}), escalating to layer #{current_layer + 1}")
            Process.sleep(jittered_delay(1000))
            do_fetch_with_layers(url, browser, retries_left, max_layer, current_layer + 1)
          
          {:challenge, type} ->
            Logger.warning("[Blink] Challenge detected (#{type}) at max layer")
            {:challenge, %{type: type, response: response, layer: current_layer}}
          
          {:blocked, reason} when retries_left > 1 ->
            Logger.info("[Blink] Blocked (#{reason}), retrying with different browser")
            next_browser = rotate_browser(browser)
            Process.sleep(jittered_delay(2000))
            do_fetch_with_layers(url, next_browser, retries_left - 1, max_layer, current_layer)
          
          {:blocked, reason} ->
            {:blocked, %{reason: reason, response: response}}
        end
      
      {:error, reason} when retries_left > 1 ->
        Logger.debug("[Blink] Error: #{inspect(reason)}, retrying...")
        Process.sleep(jittered_delay(1000))
        do_fetch_with_layers(url, browser, retries_left - 1, max_layer, current_layer)
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch_with_layers(_url, _browser, 0, _max_layer, _current_layer) do
    {:error, :max_retries_exceeded}
  end

  # Layer 0: Basic request with browser headers
  defp layer_0_fetch(url, browser) do
    Logger.debug("[Blink] Layer 0: Basic browser headers")
    basic_fetch(url, browser)
  end

  # Layer 1: Enhanced fingerprinting with proper header order
  defp layer_1_fetch(url, browser) do
    Logger.debug("[Blink] Layer 1: Enhanced fingerprinting")
    
    profile = Map.get(@browser_profiles, browser)
    headers = build_ordered_headers(profile, url)
    
    case Req.get(url, 
      headers: headers,
      redirect: true,
      max_redirects: 5,
      receive_timeout: 30_000,
      retry: false
    ) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        {:ok, %{status: status, body: body, headers: Map.new(resp_headers)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # Layer 2: TLS customization
  defp layer_2_fetch(url, browser) do
    Logger.debug("[Blink] Layer 2: TLS customization")
    
    profile = Map.get(@browser_profiles, browser)
    headers = build_ordered_headers(profile, url)
    tls_opts = build_tls_options(profile.tls_config)
    
    # Note: Req/Finch has limited TLS customization
    # For full control, we'd need to use :httpc directly or a custom adapter
    case Req.get(url,
      headers: headers,
      redirect: true,
      max_redirects: 5,
      receive_timeout: 30_000,
      retry: false,
      connect_options: [
        transport_opts: tls_opts
      ]
    ) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        {:ok, %{status: status, body: body, headers: Map.new(resp_headers)}}
      {:error, reason} ->
        # Fallback to layer 1 if TLS customization fails
        Logger.debug("[Blink] Layer 2 failed, falling back: #{inspect(reason)}")
        layer_1_fetch(url, browser)
    end
  end

  defp basic_fetch(url, browser) do
    profile = Map.get(@browser_profiles, browser)
    headers = build_basic_headers(profile)
    
    case Req.get(url,
      headers: headers,
      redirect: true,
      max_redirects: 5,
      receive_timeout: 30_000,
      retry: false
    ) do
      {:ok, %Req.Response{status: status, body: body, headers: resp_headers}} ->
        {:ok, %{status: status, body: body, headers: Map.new(resp_headers)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_basic_headers(profile) do
    base = [
      {"user-agent", profile.user_agent},
      {"accept", profile.accept},
      {"accept-language", profile.accept_language},
      {"accept-encoding", profile.accept_encoding},
      {"upgrade-insecure-requests", profile.upgrade_insecure_requests}
    ]
    
    # Add Chrome-specific headers
    if Map.has_key?(profile, :sec_ch_ua) do
      base ++ [
        {"sec-ch-ua", profile.sec_ch_ua},
        {"sec-ch-ua-mobile", profile.sec_ch_ua_mobile},
        {"sec-ch-ua-platform", profile.sec_ch_ua_platform},
        {"sec-fetch-site", "none"},
        {"sec-fetch-mode", "navigate"},
        {"sec-fetch-user", "?1"},
        {"sec-fetch-dest", "document"}
      ]
    else
      base ++ [
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
    
    # Add Chrome-specific headers
    all_headers = if Map.has_key?(profile, :sec_ch_ua) do
      Map.merge(all_headers, %{
        "sec-ch-ua" => profile.sec_ch_ua,
        "sec-ch-ua-mobile" => profile.sec_ch_ua_mobile,
        "sec-ch-ua-platform" => profile.sec_ch_ua_platform
      })
    else
      all_headers
    end
    
    # Order headers according to profile
    profile.header_order
    |> Enum.filter(&Map.has_key?(all_headers, &1))
    |> Enum.map(fn key -> {key, Map.get(all_headers, key)} end)
  end

  defp build_tls_options(tls_config) do
    # Convert cipher names to Erlang format
    ciphers = tls_config.ciphers
    |> Enum.map(&cipher_name_to_erlang/1)
    |> Enum.reject(&is_nil/1)
    
    base_opts = [
      versions: tls_config.versions,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
    
    # Add ciphers if we have valid ones
    if length(ciphers) > 0 do
      [{:ciphers, ciphers} | base_opts]
    else
      base_opts
    end
  end

  # Map human-readable cipher names to Erlang format
  defp cipher_name_to_erlang("TLS_AES_128_GCM_SHA256"), do: {:aes_128_gcm, :aes_128_gcm, :sha256}
  defp cipher_name_to_erlang("TLS_AES_256_GCM_SHA384"), do: {:aes_256_gcm, :aes_256_gcm, :sha384}
  defp cipher_name_to_erlang("TLS_CHACHA20_POLY1305_SHA256"), do: {:chacha20_poly1305, :chacha20_poly1305, :sha256}
  defp cipher_name_to_erlang("ECDHE-ECDSA-AES128-GCM-SHA256"), do: {:ecdhe_ecdsa, :aes_128_gcm, :sha256}
  defp cipher_name_to_erlang("ECDHE-RSA-AES128-GCM-SHA256"), do: {:ecdhe_rsa, :aes_128_gcm, :sha256}
  defp cipher_name_to_erlang("ECDHE-ECDSA-AES256-GCM-SHA384"), do: {:ecdhe_ecdsa, :aes_256_gcm, :sha384}
  defp cipher_name_to_erlang("ECDHE-RSA-AES256-GCM-SHA384"), do: {:ecdhe_rsa, :aes_256_gcm, :sha384}
  defp cipher_name_to_erlang("ECDHE-ECDSA-CHACHA20-POLY1305"), do: {:ecdhe_ecdsa, :chacha20_poly1305, :sha256}
  defp cipher_name_to_erlang("ECDHE-RSA-CHACHA20-POLY1305"), do: {:ecdhe_rsa, :chacha20_poly1305, :sha256}
  defp cipher_name_to_erlang(_), do: nil

  defp analyze_response_for_protection(%{status: status, body: body, headers: headers}) do
    # Check headers first
    header_detection = detect_protection_from_headers(headers)
    
    # Check body for challenge pages
    body_detection = detect_protection_from_body(body)
    
    # Combine results
    cond do
      body_detection.protection != nil ->
        %{
          protection: body_detection.protection,
          confidence: :high,
          indicators: body_detection.indicators,
          challenge_type: determine_challenge_type(status, body),
          status: status
        }
      
      header_detection.protection != nil ->
        %{
          protection: header_detection.protection,
          confidence: :medium,
          indicators: header_detection.indicators,
          challenge_type: determine_challenge_type(status, body),
          status: status
        }
      
      true ->
        %{
          protection: nil,
          confidence: :none,
          indicators: [],
          challenge_type: nil,
          status: status
        }
    end
  end

  defp detect_protection_from_headers(headers) do
    Enum.reduce(@protection_patterns, %{protection: nil, indicators: []}, fn {name, patterns}, acc ->
      found_headers = Enum.filter(patterns[:headers] || [], fn h ->
        Map.has_key?(headers, h) or Map.has_key?(headers, String.downcase(h))
      end)
      
      if length(found_headers) > 0 and acc.protection == nil do
        %{protection: name, indicators: found_headers}
      else
        acc
      end
    end)
  end

  defp detect_protection_from_body(body) when is_binary(body) do
    Enum.reduce(@protection_patterns, %{protection: nil, indicators: []}, fn {name, patterns}, acc ->
      indicators = (patterns[:challenge_indicators] || []) ++ (patterns[:challenge_titles] || [])
      
      found = Enum.filter(indicators, fn indicator ->
        String.contains?(String.downcase(body), String.downcase(indicator))
      end)
      
      if length(found) > 0 and acc.protection == nil do
        %{protection: name, indicators: found}
      else
        acc
      end
    end)
  end

  defp detect_protection_from_body(_), do: %{protection: nil, indicators: []}

  defp determine_challenge_type(status, body) do
    cond do
      status == 403 -> :blocked
      status == 429 -> :rate_limited
      status in [503, 520, 521, 522, 523, 524] -> :service_challenge
      contains_captcha?(body) -> :captcha
      contains_js_challenge?(body) -> :javascript
      contains_challenge_page?(body) -> :browser_check
      true -> nil
    end
  end

  defp contains_challenge_page?(body) when is_binary(body) do
    patterns = [
      "just a moment",
      "checking your browser",
      "please wait",
      "verify you are human",
      "browser verification",
      "ddos protection",
      "security check"
    ]
    
    body_lower = String.downcase(body)
    Enum.any?(patterns, &String.contains?(body_lower, &1))
  end

  defp contains_challenge_page?(_), do: false

  defp contains_captcha?(body) when is_binary(body) do
    patterns = ["captcha", "recaptcha", "hcaptcha", "turnstile", "g-recaptcha"]
    body_lower = String.downcase(body)
    Enum.any?(patterns, &String.contains?(body_lower, &1))
  end

  defp contains_captcha?(_), do: false

  defp contains_js_challenge?(body) when is_binary(body) do
    # JavaScript challenge indicators
    patterns = [
      "cf_chl_opt",
      "_cf_chl_tk",
      "challenge-platform",
      "window._cf_chl_enter"
    ]
    
    Enum.any?(patterns, &String.contains?(body, &1))
  end

  defp contains_js_challenge?(_), do: false

  defp rotate_browser(current) do
    browsers = [:chrome_136, :firefox_135, :safari_18]
    current_index = Enum.find_index(browsers, &(&1 == current)) || 0
    Enum.at(browsers, rem(current_index + 1, length(browsers)))
  end

  defp jittered_delay(base_ms) do
    # Add 0-50% jitter
    jitter = :rand.uniform(div(base_ms, 2))
    base_ms + jitter
  end

  # Advanced techniques for future implementation
  
  @doc """
  Solve JavaScript challenges using a headless browser.
  
  NOTE: This requires external dependencies (playwright/puppeteer via Port)
  and is not yet implemented.
  """
  def solve_js_challenge(_url, _opts \\ []) do
    {:error, :not_implemented}
  end

  @doc """
  Use curl_cffi for advanced TLS fingerprinting via Python bridge.
  
  This provides the most accurate browser impersonation but requires Python.
  """
  def fetch_via_curl_cffi(url, opts \\ []) do
    browser = Keyword.get(opts, :browser, "chrome136")
    timeout = Keyword.get(opts, :timeout, 30000)
    
    # Python script for curl_cffi
    python_script = """
    import sys
    import json
    from curl_cffi import requests
    
    url = sys.argv[1]
    browser = sys.argv[2]
    
    try:
        response = requests.get(url, impersonate=browser, timeout=#{div(timeout, 1000)})
        result = {
            "status": response.status_code,
            "body": response.text,
            "headers": dict(response.headers)
        }
        print(json.dumps(result))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
    """
    
    # Check if Python and curl_cffi are available
    case System.cmd("python3", ["-c", "from curl_cffi import requests"], stderr_to_stdout: true) do
      {_, 0} ->
        # Write temp script
        script_path = Path.join(System.tmp_dir!(), "blink_curl_cffi_#{:rand.uniform(100000)}.py")
        File.write!(script_path, python_script)
        
        try do
          case System.cmd("python3", [script_path, url, browser], stderr_to_stdout: true) do
            {output, 0} ->
              case Jason.decode(output) do
                {:ok, %{"error" => error}} -> {:error, error}
                {:ok, %{"status" => status, "body" => body, "headers" => headers}} ->
                  {:ok, %{status: status, body: body, headers: headers, method: :curl_cffi}}
                {:error, _} -> {:error, :json_decode_failed}
              end
            {error, _} ->
              {:error, error}
          end
        after
          File.rm(script_path)
        end
      
      {_, _} ->
        {:error, :curl_cffi_not_available}
    end
  end

  @doc """
  Get session cookies after passing a challenge.
  
  This can be used to persist challenge solutions for subsequent requests.
  """
  def get_session_cookies(%{headers: headers}) do
    case Map.get(headers, "set-cookie") || Map.get(headers, "Set-Cookie") do
      nil -> []
      cookies when is_list(cookies) -> Enum.map(cookies, &parse_cookie/1)
      cookie when is_binary(cookie) -> [parse_cookie(cookie)]
    end
  end

  defp parse_cookie(cookie_string) do
    [name_value | attributes] = String.split(cookie_string, ";")
    [name, value] = String.split(name_value, "=", parts: 2)
    
    %{
      name: String.trim(name),
      value: String.trim(value),
      attributes: Enum.map(attributes, &String.trim/1)
    }
  end

  @doc """
  Analyze a site's protection configuration.
  
  Returns detailed information about the protection setup.
  """
  def analyze_protection(url) do
    Logger.info("[Blink] Analyzing protection for #{url}")
    
    with {:ok, response} <- basic_fetch(url, :chrome_136),
         detection <- detect_protection(response) do
      
      # Try to gather more info
      additional_info = %{
        cookies_required: get_session_cookies(response),
        status_code: response.status,
        server: Map.get(response.headers, "server"),
        cdn: detect_cdn(response.headers)
      }
      
      {:ok, Map.merge(detection, additional_info)}
    end
  end

  defp detect_cdn(headers) do
    cond do
      Map.has_key?(headers, "cf-ray") -> :cloudflare
      Map.has_key?(headers, "x-amz-cf-id") -> :aws_cloudfront
      Map.has_key?(headers, "x-akamai-transformed") -> :akamai
      Map.has_key?(headers, "x-served-by") and String.contains?(Map.get(headers, "x-served-by", ""), "fastly") -> :fastly
      true -> nil
    end
  end
end
