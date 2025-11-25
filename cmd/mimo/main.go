// Package main implements the mimo CLI - a shell-native interface to the Mimo Memory OS.
//
// The CLI wraps HTTP calls to the Mimo Universal Aperture gateway, enabling
// Unix-style composability with grep, awk, xargs, and shell pipelines.
//
// Usage:
//
//	mimo ask "How do I center a div with Flexbox?"
//	mimo run search_vibes --query "foreboding atmosphere" --limit 5
//	git diff | mimo ask "suggest a commit message" | git commit -F -
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	defaultEndpoint = "http://localhost:4000"
	version         = "2.2.0"
)

var (
	apiKey   string
	endpoint string
	sandbox  bool
	timeout  int
	verbose  bool
)

func init() {
	flag.StringVar(&apiKey, "api-key", os.Getenv("MIMO_API_KEY"), "API key for authentication")
	flag.StringVar(&endpoint, "endpoint", getEnvOrDefault("MIMO_ENDPOINT", defaultEndpoint), "Mimo HTTP endpoint")
	flag.BoolVar(&sandbox, "sandbox", false, "Enable sandbox mode (disables store operations)")
	flag.IntVar(&timeout, "timeout", 5000, "Request timeout in milliseconds")
	flag.BoolVar(&verbose, "verbose", false, "Enable verbose output")
}

func main() {
	flag.Parse()

	if len(flag.Args()) == 0 {
		printUsage()
		os.Exit(1)
	}

	cmd := flag.Arg(0)

	switch cmd {
	case "ask":
		handleAsk()
	case "run":
		handleRun()
	case "tools":
		handleTools()
	case "health":
		handleHealth()
	case "version":
		fmt.Printf("mimo version %s\n", version)
	case "help":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", cmd)
		printUsage()
		os.Exit(1)
	}
}

func handleAsk() {
	query := getQueryFromArgsOrStdin()
	if query == "" {
		fmt.Fprintln(os.Stderr, "Error: No query provided")
		os.Exit(1)
	}

	payload := map[string]interface{}{
		"query":      query,
		"timeout_ms": timeout,
	}

	resp, err := makeRequest("POST", "/v1/mimo/ask", payload)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// Extract and print the synthesis or results as plain text
	printAskResponse(resp)
}

func handleRun() {
	if len(flag.Args()) < 2 {
		fmt.Fprintln(os.Stderr, "Error: Tool name required")
		fmt.Fprintln(os.Stderr, "Usage: mimo run <tool> [--arg value...]")
		os.Exit(1)
	}

	tool := flag.Arg(1)
	arguments := parseToolArgs(flag.Args()[2:])

	payload := map[string]interface{}{
		"tool":      tool,
		"arguments": arguments,
	}

	resp, err := makeRequest("POST", "/v1/mimo/tool", payload)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	printToolResponse(resp)
}

func handleTools() {
	resp, err := makeRequest("GET", "/v1/mimo/tools", nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	tools, ok := resp["tools"].([]interface{})
	if !ok {
		fmt.Println("No tools available")
		return
	}

	fmt.Println("Available tools:")
	for _, t := range tools {
		tool := t.(map[string]interface{})
		name := tool["name"].(string)
		desc := tool["description"].(string)
		fmt.Printf("  %s\n    %s\n", name, desc)
	}
}

func handleHealth() {
	resp, err := makeRequest("GET", "/health", nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if verbose {
		prettyJSON, _ := json.MarshalIndent(resp, "", "  ")
		fmt.Println(string(prettyJSON))
	} else {
		status := resp["status"].(string)
		version := resp["version"].(string)
		fmt.Printf("Status: %s (v%s)\n", status, version)
	}
}

func getQueryFromArgsOrStdin() string {
	// Check if query is in args
	if len(flag.Args()) > 1 {
		return strings.Join(flag.Args()[1:], " ")
	}

	// Check if stdin has data (piped input)
	stat, _ := os.Stdin.Stat()
	if (stat.Mode() & os.ModeCharDevice) == 0 {
		input, _ := io.ReadAll(os.Stdin)
		return strings.TrimSpace(string(input))
	}

	return ""
}

func parseToolArgs(args []string) map[string]interface{} {
	result := make(map[string]interface{})

	for i := 0; i < len(args); i++ {
		arg := args[i]
		if strings.HasPrefix(arg, "--") {
			key := strings.TrimPrefix(arg, "--")
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "--") {
				result[key] = args[i+1]
				i++
			} else {
				result[key] = true
			}
		}
	}

	return result
}

func makeRequest(method, path string, payload interface{}) (map[string]interface{}, error) {
	url := endpoint + path

	var body io.Reader
	if payload != nil {
		jsonData, err := json.Marshal(payload)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal payload: %w", err)
		}
		body = bytes.NewReader(jsonData)
	}

	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	if apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+apiKey)
	}
	if sandbox {
		req.Header.Set("X-Mimo-Sandbox", "true")
	}

	client := &http.Client{
		Timeout: time.Duration(timeout) * time.Millisecond,
	}

	if verbose {
		fmt.Fprintf(os.Stderr, "[DEBUG] %s %s\n", method, url)
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if verbose {
		fmt.Fprintf(os.Stderr, "[DEBUG] Response: %s\n", string(respBody))
	}

	var result map[string]interface{}
	if err := json.Unmarshal(respBody, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if resp.StatusCode >= 400 {
		errMsg := "unknown error"
		if e, ok := result["error"].(string); ok {
			errMsg = e
		}
		return nil, fmt.Errorf("API error (%d): %s", resp.StatusCode, errMsg)
	}

	return result, nil
}

func printAskResponse(resp map[string]interface{}) {
	// Try to get synthesis first (most useful for piping)
	if synthesis, ok := resp["synthesis"].(string); ok && synthesis != "" {
		fmt.Println(synthesis)
		return
	}

	// Fall back to results
	if results, ok := resp["results"].(map[string]interface{}); ok {
		if episodic, ok := results["episodic"].([]interface{}); ok && len(episodic) > 0 {
			for _, item := range episodic {
				if m, ok := item.(map[string]interface{}); ok {
					if content, ok := m["content"].(string); ok {
						fmt.Printf("• %s\n", content)
					}
				}
			}
		}
	}

	// Show router decision in verbose mode
	if verbose {
		if decision, ok := resp["router_decision"].(map[string]interface{}); ok {
			fmt.Fprintf(os.Stderr, "[ROUTER] Store: %v, Confidence: %v\n",
				decision["primary_store"], decision["confidence"])
		}
	}
}

func printToolResponse(resp map[string]interface{}) {
	if data, ok := resp["data"]; ok {
		// Pretty print for complex data
		switch v := data.(type) {
		case []interface{}:
			for _, item := range v {
				if m, ok := item.(map[string]interface{}); ok {
					if content, ok := m["content"].(string); ok {
						fmt.Printf("• %s\n", content)
					} else {
						json, _ := json.MarshalIndent(m, "", "  ")
						fmt.Println(string(json))
					}
				}
			}
		case map[string]interface{}:
			json, _ := json.MarshalIndent(v, "", "  ")
			fmt.Println(string(json))
		default:
			fmt.Println(v)
		}
	}
}

func printUsage() {
	fmt.Println(`mimo - Shell interface to Mimo Memory OS

USAGE:
    mimo <command> [options] [arguments]

COMMANDS:
    ask <query>             Query the Meta-Cognitive Router
    run <tool> [--args]     Execute a specific tool
    tools                   List available tools
    health                  Check system health
    version                 Show version
    help                    Show this help

EXAMPLES:
    # Natural language query
    mimo ask "How do I center a div with Flexbox?"

    # Vector similarity search
    mimo run search_vibes --query "mysterious atmosphere" --limit 5

    # Store a fact
    mimo run store_fact --content "User prefers dark mode" --category fact

    # Shell pipeline (git commit message)
    git diff | mimo ask "Write a concise commit message" | git commit -F -

    # Sandbox mode (safe for untrusted scripts)
    mimo --sandbox ask "What are the best practices for error handling?"

OPTIONS:
    --api-key <key>     API key (or set MIMO_API_KEY env var)
    --endpoint <url>    Mimo endpoint (default: http://localhost:4000)
    --sandbox           Disable write operations
    --timeout <ms>      Request timeout (default: 5000)
    --verbose           Enable debug output

ENVIRONMENT:
    MIMO_API_KEY        API key for authentication
    MIMO_ENDPOINT       HTTP endpoint URL`)
}

func getEnvOrDefault(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}
