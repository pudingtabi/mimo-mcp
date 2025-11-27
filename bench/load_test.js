/**
 * k6 Load Test for Mimo-MCP
 * 
 * Run with:
 *   k6 run bench/load_test.js
 * 
 * Or with custom parameters:
 *   k6 run --vus 200 --duration 5m bench/load_test.js
 * 
 * Success Criteria:
 *   - p95 latency < 500ms
 *   - p99 latency < 1000ms
 *   - Error rate < 1%
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend } from 'k6/metrics';

// Custom metrics
const errorRate = new Rate('errors');
const healthLatency = new Trend('health_latency', true);
const askLatency = new Trend('ask_latency', true);
const toolsLatency = new Trend('tools_latency', true);

// Test configuration
export const options = {
  stages: [
    { duration: '30s', target: 20 },   // Ramp up
    { duration: '2m', target: 100 },   // Hold at 100 VUs
    { duration: '1m', target: 200 },   // Spike to 200
    { duration: '2m', target: 100 },   // Back to 100
    { duration: '30s', target: 0 },    // Ramp down
  ],
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
    errors: ['rate<0.01'],
    health_latency: ['p(95)<100'],
    ask_latency: ['p(95)<500'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:4000';

// Test queries for variety
const TEST_QUERIES = [
  'What is the current time?',
  'List available tools',
  'Search for recent memories',
  'Explain the weather',
  'Calculate 2 + 2',
  'Show system status',
  'Find documents about testing',
  'Summarize the project',
  'What can you do?',
  'Help me with coding',
];

export default function() {
  group('Health Check', function() {
    const res = http.get(`${BASE_URL}/health`);
    healthLatency.add(res.timings.duration);
    
    const success = check(res, {
      'health status 200': (r) => r.status === 200,
      'health response valid': (r) => {
        try {
          const body = JSON.parse(r.body);
          return body.status === 'ok' || body.status === 'healthy';
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!success);
  });

  sleep(0.1);

  group('Ask Endpoint', function() {
    const query = TEST_QUERIES[Math.floor(Math.random() * TEST_QUERIES.length)];
    const payload = JSON.stringify({ query: query });
    const params = {
      headers: { 'Content-Type': 'application/json' },
      timeout: '10s',
    };

    const res = http.post(`${BASE_URL}/api/ask`, payload, params);
    askLatency.add(res.timings.duration);

    const success = check(res, {
      'ask status 2xx': (r) => r.status >= 200 && r.status < 300,
      'ask has response': (r) => r.body && r.body.length > 0,
    });
    errorRate.add(!success);
  });

  sleep(0.1);

  group('Tools List', function() {
    const res = http.get(`${BASE_URL}/api/tools`);
    toolsLatency.add(res.timings.duration);

    const success = check(res, {
      'tools status 200': (r) => r.status === 200,
      'tools response is array': (r) => {
        try {
          const body = JSON.parse(r.body);
          return Array.isArray(body) || (body.tools && Array.isArray(body.tools));
        } catch {
          return false;
        }
      },
    });
    errorRate.add(!success);
  });

  sleep(0.1);
}

// Lifecycle hooks
export function setup() {
  console.log(`Testing against: ${BASE_URL}`);
  
  // Verify server is up
  const res = http.get(`${BASE_URL}/health`);
  if (res.status !== 200) {
    throw new Error(`Server not ready at ${BASE_URL}`);
  }
  
  return { baseUrl: BASE_URL };
}

export function teardown(data) {
  console.log(`Load test completed against ${data.baseUrl}`);
}

// Custom summary
export function handleSummary(data) {
  const summary = {
    timestamp: new Date().toISOString(),
    vus_max: data.metrics.vus_max ? data.metrics.vus_max.values.max : 0,
    iterations: data.metrics.iterations ? data.metrics.iterations.values.count : 0,
    duration_ms: data.state.testRunDurationMs,
    http_reqs: data.metrics.http_reqs ? data.metrics.http_reqs.values.count : 0,
    latency: {
      avg: data.metrics.http_req_duration ? data.metrics.http_req_duration.values.avg : 0,
      p95: data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(95)'] : 0,
      p99: data.metrics.http_req_duration ? data.metrics.http_req_duration.values['p(99)'] : 0,
    },
    error_rate: data.metrics.http_req_failed ? data.metrics.http_req_failed.values.rate * 100 : 0,
    thresholds_passed: Object.values(data.root_group.checks || {})
      .every(c => c.passes === c.fails + c.passes),
  };

  return {
    stdout: textSummary(data, { indent: ' ', enableColors: true }),
    'bench/results/k6_summary.json': JSON.stringify(summary, null, 2),
  };
}

function textSummary(data, options) {
  let output = '\n';
  output += '='.repeat(60) + '\n';
  output += 'K6 LOAD TEST RESULTS\n';
  output += '='.repeat(60) + '\n\n';
  
  output += `Max VUs: ${data.metrics.vus_max?.values.max || 0}\n`;
  output += `Iterations: ${data.metrics.iterations?.values.count || 0}\n`;
  output += `Duration: ${(data.state.testRunDurationMs / 1000).toFixed(1)}s\n\n`;
  
  output += 'Latency (ms):\n';
  output += `  avg: ${(data.metrics.http_req_duration?.values.avg || 0).toFixed(1)}\n`;
  output += `  p95: ${(data.metrics.http_req_duration?.values['p(95)'] || 0).toFixed(1)}\n`;
  output += `  p99: ${(data.metrics.http_req_duration?.values['p(99)'] || 0).toFixed(1)}\n\n`;
  
  output += `Error Rate: ${((data.metrics.http_req_failed?.values.rate || 0) * 100).toFixed(2)}%\n\n`;
  
  output += '='.repeat(60) + '\n';
  
  return output;
}
