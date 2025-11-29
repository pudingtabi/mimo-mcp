# 🚀 Search Evolution Roadmap: Climbing Beyond Exa & Tavily

> **Mission**: Build search and content extraction capabilities that match or exceed commercial services like Exa, Tavily, and Firecrawl - using only OpenRouter + local tools.

## 📊 Competitive Analysis

### What Exa/Tavily Provide:
| Feature | Exa | Tavily | Our Goal |
|---------|-----|--------|----------|
| Neural/Semantic Search | ✅ | ✅ | ✅ (Qwen embeddings) |
| Clean Content Extraction | ✅ | ✅ | 🚧 Building |
| Cloudflare Bypass | ✅ | ✅ | 🔨 Phase 3-4 |
| Real-time Search | ✅ | ✅ | ✅ (DDG) |
| Structured Output | ✅ | ✅ | ✅ |
| JavaScript Rendering | ✅ | ✅ | 🔨 Phase 3 |
| **Cost** | $$$$ | $$$$ | **FREE** |

---

## 🎯 Phase 1: Multi-Backend Search (IMMEDIATE)
**Status**: Ready to implement
**Effort**: 2-4 hours

### Current State
- DDG HTML scraping works ✅
- Returns title, snippet, URL ✅
- ~80% of queries work ✅

### Enhancements

#### 1.1 Add Bing HTML Search Backend
```elixir
# In lib/mimo/skills/network.ex

def search_bing(query, num_results \\ 10) do
  url = "https://www.bing.com/search?q=#{URI.encode(query)}&count=#{num_results}"
  
  case Req.get(url, headers: browser_headers()) do
    {:ok, %{status: 200, body: body}} ->
      parse_bing_results(body)
    _ ->
      {:error, "Bing search failed"}
  end
end
```

#### 1.2 Add Brave Search Fallback
Brave Search has less aggressive bot protection:
```elixir
def search_brave(query, num_results \\ 10) do
  url = "https://search.brave.com/search?q=#{URI.encode(query)}"
  # Parse HTML results
end
```

#### 1.3 Smart Search Orchestration
```elixir
def smart_search(query, opts \\ []) do
  backends = [:duckduckgo, :bing, :brave]
  
  # Try backends in order, fallback on failure
  Enum.reduce_while(backends, {:error, "All backends failed"}, fn backend, _acc ->
    case search_with_backend(backend, query, opts) do
      {:ok, results} when length(results) > 0 -> {:halt, {:ok, results}}
      _ -> {:cont, {:error, "Backend #{backend} failed"}}
    end
  end)
end
```

---

## 🧠 Phase 2: AI-Powered Content Extraction (THIS WEEK)
**Status**: Design phase
**Effort**: 4-8 hours

### The Problem
We can fetch HTML, but extracting CLEAN CONTENT is hard:
- Ads, navigation, footers
- JavaScript-rendered content
- Different site structures

### The Solution: AI Content Extraction

#### 2.1 Readability-Style Extraction
Use Mozilla's Readability algorithm ported to Elixir or via Floki:
```elixir
def extract_content(html) do
  # 1. Parse HTML
  {:ok, doc} = Floki.parse_document(html)
  
  # 2. Remove noise (scripts, styles, nav, footer, ads)
  doc
  |> Floki.filter_out("script, style, nav, footer, aside, .ad, .advertisement")
  
  # 3. Score content blocks by text density
  |> score_content_blocks()
  
  # 4. Extract main content
  |> extract_highest_scored()
end
```

#### 2.2 AI Summarization + Extraction
When HTML is messy, use OpenRouter to extract:
```elixir
def ai_extract_content(html, query) do
  prompt = """
  Extract the main content from this HTML that's relevant to: #{query}
  
  Return as JSON:
  {
    "title": "...",
    "content": "...",
    "key_facts": ["...", "..."],
    "date": "...",
    "author": "..."
  }
  
  HTML:
  #{String.slice(html, 0, 50000)}
  """
  
  Mimo.Brain.LLM.chat([
    %{role: "system", content: "You are a content extraction expert."},
    %{role: "user", content: prompt}
  ])
end
```

#### 2.3 Structured Data Extraction
Many sites have JSON-LD, OpenGraph, etc:
```elixir
def extract_structured_data(html) do
  {:ok, doc} = Floki.parse_document(html)
  
  # Extract JSON-LD
  json_ld = doc
  |> Floki.find("script[type='application/ld+json']")
  |> Floki.text()
  |> Jason.decode()
  
  # Extract OpenGraph
  og_data = doc
  |> Floki.find("meta[property^='og:']")
  |> Enum.map(fn el -> 
    {Floki.attribute(el, "property"), Floki.attribute(el, "content")}
  end)
  |> Map.new()
  
  %{json_ld: json_ld, opengraph: og_data}
end
```

---

## 🎭 Phase 3: Playwright Integration (NEXT WEEK)
**Status**: Research phase
**Effort**: 1-2 days

### Why Playwright?
- Renders JavaScript
- Handles dynamic content
- Bypasses basic bot detection
- Can interact with pages (login, scroll, click)

### Implementation Options

#### Option A: Elixir Port to Node.js Playwright
```elixir
# lib/mimo/browser/playwright.ex
defmodule Mimo.Browser.Playwright do
  use GenServer
  
  def start_link(_) do
    port = Port.open({:spawn, "node #{playwright_script()}"}, [:binary, :exit_status])
    {:ok, %{port: port}}
  end
  
  def fetch_with_browser(url, opts \\ []) do
    GenServer.call(__MODULE__, {:fetch, url, opts})
  end
  
  def handle_call({:fetch, url, opts}, _from, state) do
    # Send command to Node.js Playwright process
    Port.command(state.port, Jason.encode!(%{action: "fetch", url: url, opts: opts}))
    # Receive response
    receive do
      {_port, {:data, data}} -> {:reply, Jason.decode!(data), state}
    end
  end
end
```

#### Option B: Docker Sidecar with Browserless
```yaml
# docker-compose.yml
services:
  mimo:
    build: .
    depends_on:
      - browserless
      
  browserless:
    image: browserless/chrome
    environment:
      - MAX_CONCURRENT_SESSIONS=5
```

Then use CDP (Chrome DevTools Protocol):
```elixir
def fetch_with_browserless(url) do
  # Connect to browserless instance
  {:ok, ws} = WebSockex.start("ws://browserless:3000")
  
  # Navigate and get content
  # ...
end
```

#### Option C: Use Crawlee (Node.js) via MCP
Add a dedicated browser scraping MCP server:
```javascript
// bin/browser-mcp-server.js
import { chromium } from 'playwright';

const browser = await chromium.launch();

async function fetchWithBrowser(url) {
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'networkidle' });
  const content = await page.content();
  await page.close();
  return content;
}
```

---

## 🛡️ Phase 4: Advanced TLS Bypass (FUTURE)
**Status**: Research phase
**Effort**: Complex

### The Challenge
Even with Playwright, Cloudflare can detect:
- TLS fingerprint (JA3)
- Browser fingerprint
- Behavioral patterns
- IP reputation

### Approaches

#### 4.1 TLS Fingerprint Spoofing
Use `curl_cffi` (Python) or `tls-client` (Go):
```python
# Via Python port
from curl_cffi import requests

response = requests.get(
    "https://protected-site.com",
    impersonate="chrome110"
)
```

#### 4.2 Stealth Playwright
```javascript
// Use playwright-extra with stealth plugin
const { chromium } = require('playwright-extra');
const stealth = require('puppeteer-extra-plugin-stealth')();

chromium.use(stealth);
const browser = await chromium.launch();
```

#### 4.3 Residential Proxies (Paid)
For serious scale, rotate IPs:
```elixir
def fetch_with_proxy(url) do
  proxy = get_rotating_proxy()
  Req.get(url, proxy: proxy)
end
```

---

## 📈 Implementation Priority

| Priority | Phase | Feature | Impact | Effort |
|----------|-------|---------|--------|--------|
| 🔴 HIGH | 1 | Multi-backend search | High | Low |
| 🔴 HIGH | 2 | AI content extraction | High | Medium |
| 🟡 MEDIUM | 2 | Structured data extraction | Medium | Low |
| 🟡 MEDIUM | 3 | Playwright basic | High | Medium |
| 🟢 LOW | 3 | Browserless Docker | High | Medium |
| 🟢 LOW | 4 | TLS spoofing | High | High |

---

## 🚀 Quick Wins (Do Today)

### 1. Add Bing Search Backend
Add to `lib/mimo/skills/network.ex` - 30 minutes

### 2. Improve DDG Parsing
Better snippet extraction - 15 minutes

### 3. Add User-Agent Rotation
Simple but effective - 10 minutes

### 4. Content Extraction Tool
New MCP tool `web_extract` - 1 hour

---

## 🎯 Success Metrics

| Metric | Current | Phase 1 | Phase 2 | Phase 3 |
|--------|---------|---------|---------|---------|
| Search Success Rate | 70% | 85% | 90% | 95% |
| Content Quality | Basic | Good | Excellent | Excellent |
| JS Sites Support | 0% | 0% | 20% | 80% |
| Cloudflare Bypass | 0% | 0% | 0% | 30% |
| Speed (avg) | 500ms | 600ms | 800ms | 2000ms |

---

## 💡 Philosophy

> "Exa and Tavily are not enemies - they are stairs to climb and surpass."

We don't need to match them feature-for-feature. We need to:
1. **Leverage AI** - Use OpenRouter to intelligently process whatever we CAN fetch
2. **Be Smart** - Use snippets when full content is blocked
3. **Build Incrementally** - Each phase adds capability
4. **Stay Free** - No paid APIs, no subscriptions

The goal isn't to scrape everything - it's to **get the information we need** to answer questions and complete tasks.

---

## 🛠️ Next Steps

1. [ ] Implement Phase 1 multi-backend search
2. [ ] Add `web_extract` tool with AI extraction
3. [ ] Create Playwright integration spike
4. [ ] Benchmark against Exa/Tavily for comparison

---

*Last Updated: November 29, 2025*
