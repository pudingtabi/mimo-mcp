# Test Blink module

IO.puts("Testing Blink on OpenAI.com (Cloudflare protected)...")

case Mimo.Skills.Blink.fetch("https://openai.com") do
  {:ok, response} ->
    IO.puts("SUCCESS")
    IO.puts("Status: #{response.status}")
    IO.puts("Layer used: #{response.layer_used}")
    
    # Handle binary/compressed body
    body = case response.body do
      b when is_binary(b) ->
        # Try to decompress if gzip
        case :zlib.gunzip(b) do
          decompressed when is_binary(decompressed) -> decompressed
          _ -> b
        end
      other -> to_string(other)
    end
    
    body_str = if String.valid?(body), do: body, else: "(binary data)"
    IO.puts("Body length: #{byte_size(response.body)} bytes")
    
    # Check for challenge indicators
    if String.valid?(body_str) and String.contains?(body_str, "Just a moment") do
      IO.puts("WARNING: Got Cloudflare challenge page")
    else
      IO.puts("Got actual content")
      # Show first 500 chars
      IO.puts("\nContent preview:")
      preview = if String.valid?(body_str), do: String.slice(body_str, 0..500), else: "(binary)"
      IO.puts(preview)
    end
    
  {:challenge, info} ->
    IO.puts("CHALLENGE detected: #{inspect(info.type)}")
    IO.puts("Layer: #{info.layer}")
    
  {:blocked, info} ->
    IO.puts("BLOCKED: #{inspect(info.reason)}")
    
  {:error, reason} ->
    IO.puts("ERROR: #{inspect(reason)}")
end

IO.puts("\n---\n")

# Test protection analysis
IO.puts("Analyzing protection...")
case Mimo.Skills.Blink.analyze_protection("https://openai.com") do
  {:ok, info} ->
    IO.puts("Protection: #{inspect(info.protection)}")
    IO.puts("Confidence: #{inspect(info.confidence)}")
    IO.puts("Challenge type: #{inspect(info.challenge_type)}")
    IO.puts("CDN: #{inspect(info.cdn)}")
    IO.puts("Indicators: #{inspect(info.indicators)}")
  {:error, reason} ->
    IO.puts("Analysis error: #{inspect(reason)}")
end
