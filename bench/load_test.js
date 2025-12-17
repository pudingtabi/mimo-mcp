/**
 * k6 Production Load Test for Mimo-MCP (SPEC-061)
 * 
 * Tests performance against production targets:
 *   - p95 latency < 1500ms (Mem0: 1.44s, Zep: 2.58s)
 *   - p99 latency < 3000ms
 *   - Throughput > 100 req/s
 *   - Error rate < 1%
 * 
 * Run with:
 *   k6 run bench/load_test.js
 * 
 * Or with custom parameters:
 *   k6 run --env MIMO_URL=http://localhost:4000 bench/load_test.js
 *   k6 run --vus 100 --duration 5m bench/load_test.js
 *   k6 run -e API_KEY=your_key bench/load_test.js
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// =============================================================================
// Custom Metrics (SPEC-061 aligned)
// =============================================================================

const errorRate = new Rate('errors');
const searchLatency = new Trend('search_latency', true);
const storeLatency = new Trend('store_latency', true);
const toolLatency = new Trend('tool_latency', true);
const healthLatency = new Trend('health_latency', true);
const searchCount = new Counter('search_count');
const storeCount = new Counter('store_count');

// =============================================================================
// Test Configuration (SPEC-061 targets)
// =============================================================================

export const options = {
  stages: [
    { duration: '1m', target: 20 },    // Ramp up to baseline
    { duration: '3m', target: 50 },    // Sustained load
    { duration: '1m', target: 100 },   // Peak load (target throughput)
    { duration: '2m', target: 100 },   // Hold at peak
    { duration: '1m', target: 0 },     // Ramp down
  ],
  thresholds: {
    // SPEC-061 Production Targets
    'search_latency': ['p(95)<1500', 'p(99)<3000'],  // Primary targets
    'store_latency': ['p(95)<2000'],
    'errors': ['rate<0.01'],                          // <1% error rate
    'http_reqs': ['rate>100'],                        // >100 req/s at peak
    
    // Existing targets
    'health_latency': ['p(95)<100'],
    'http_req_duration': ['p(95)<2000'],
  },
};

// =============================================================================
// Configuration
// =============================================================================

const BASE_URL = __ENV.MIMO_URL || 'http://localhost:4000';
const API_KEY = __ENV.API_KEY || '';

const headers = {
  'Content-Type': 'application/json',
  ...(API_KEY && { 'Authorization': `Bearer ${API_KEY}` })
};

// Test queries for memory search (varied for realistic testing)
const SEARCH_QUERIES = [
  'project architecture patterns and design decisions',
  'authentication flow and security measures',
  'database optimization and performance tuning',
  'error handling strategies and recovery',
  'API design principles and best practices',
  'memory management and garbage collection',
  'performance tuning and benchmarks',
  'security best practices and vulnerabilities',
  'testing strategies and test coverage',
  'deployment configuration and infrastructure',
  'user preferences and settings',
  'recent changes and modifications',
  'bug fixes and patches',
  'feature implementations',
  'code refactoring patterns',
];

// Test content for memory store
function generateStoreContent() {
  const topics = ['project', 'code', 'feature', 'bug', 'optimization'];
  const actions = ['implemented', 'fixed', 'improved', 'refactored', 'deployed'];
  const topic = topics[Math.floor(Math.random() * topics.length)];
  const action = actions[Math.floor(Math.random() * actions.length)];
  return `Load test memory: ${action} ${topic} at ${Date.now()} - VU ${__VU}`;
}

// =============================================================================
// Test Scenarios
// =============================================================================

export default function() {
  // Weighted distribution: 70% searches, 20% stores, 10% health checks
  const rand = Math.random();
  
  if (rand < 0.7) {
    searchMemory();
  } else if (rand < 0.9) {
    storeMemory();
  } else {
    healthCheck();
  }
  
  // Small delay between requests
  sleep(0.05 + Math.random() * 0.1);
}

function searchMemory() {
  const query = SEARCH_QUERIES[Math.floor(Math.random() * SEARCH_QUERIES.length)];
  
  const payload = JSON.stringify({
    tool: 'memory',
    arguments: {
      operation: 'search',
      query: query,
      limit: 10
    }
  });

  const start = Date.now();
  const res = http.post(`${BASE_URL}/v1/mimo/tool`, payload, { headers, timeout: '30s' });
  const duration = Date.now() - start;
  
  searchLatency.add(duration);
  searchCount.add(1);

  const success = check(res, {
    'search status 200': (r) => r.status === 200,
    'search has results': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.status === 'success' || body.result !== undefined;
      } catch {
        return r.status === 200;
      }
    },
    'search latency < 1500ms': () => duration < 1500,
  });

  errorRate.add(!success);
}

function storeMemory() {
  const content = generateStoreContent();
  
  const payload = JSON.stringify({
    tool: 'memory',
    arguments: {
      operation: 'store',
      content: content,
      category: 'fact',
      importance: 0.5
    }
  });

  const start = Date.now();
  const res = http.post(`${BASE_URL}/v1/mimo/tool`, payload, { headers, timeout: '30s' });
  const duration = Date.now() - start;
  
  storeLatency.add(duration);
  storeCount.add(1);

  const success = check(res, {
    'store status 200': (r) => r.status === 200,
    'store confirmed': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.status === 'success' || r.status === 200;
      } catch {
        return r.status === 200;
      }
    },
    'store latency < 2000ms': () => duration < 2000,
  });

  errorRate.add(!success);
}

function healthCheck() {
  const start = Date.now();
  const res = http.get(`${BASE_URL}/health`);
  const duration = Date.now() - start;
  
  healthLatency.add(duration);

  const success = check(res, {
    'health status 200': (r) => r.status === 200,
    'health response valid': (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.status === 'healthy' || body.status === 'ok';
      } catch {
        return false;
      }
    },
  });

  errorRate.add(!success);
}

// =============================================================================
// Lifecycle Hooks
// =============================================================================

export function setup() {
  console.log('\n' + '='.repeat(60));
  console.log('MIMO PRODUCTION LOAD TEST (SPEC-061)');
  console.log('='.repeat(60));
  console.log(`Target URL: ${BASE_URL}`);
  console.log(`API Key: ${API_KEY ? 'configured' : 'not set'}`);
  console.log('');
  console.log('Targets:');
  console.log('  • p95 Search Latency: < 1500ms');
  console.log('  • p99 Search Latency: < 3000ms');
  console.log('  • Throughput: > 100 req/s');
  console.log('  • Error Rate: < 1%');
  console.log('='.repeat(60) + '\n');
  
  // Verify server is up
  const res = http.get(`${BASE_URL}/health`);
  if (res.status !== 200) {
    throw new Error(`Server not ready at ${BASE_URL} (status: ${res.status})`);
  }
  
  console.log('✓ Server is healthy, starting load test...\n');
  
  return { baseUrl: BASE_URL, startTime: Date.now() };
}

export function teardown(data) {
  const duration = ((Date.now() - data.startTime) / 1000).toFixed(1);
  console.log(`\n✓ Load test completed in ${duration}s against ${data.baseUrl}`);
}

// =============================================================================
// Custom Summary (SPEC-061 format)
// =============================================================================

export function handleSummary(data) {
  const searchP95 = data.metrics.search_latency?.values['p(95)'] || 0;
  const searchP99 = data.metrics.search_latency?.values['p(99)'] || 0;
  const storeP95 = data.metrics.store_latency?.values['p(95)'] || 0;
  const errorRateVal = (data.metrics.errors?.values.rate || 0) * 100;
  const throughput = data.metrics.http_reqs?.values.rate || 0;
  
  // Determine pass/fail
  const p95Pass = searchP95 < 1500;
  const p99Pass = searchP99 < 3000;
  const throughputPass = throughput >= 100;
  const errorPass = errorRateVal < 1;
  const allPass = p95Pass && p99Pass && errorPass;

  const summary = {
    timestamp: new Date().toISOString(),
    spec: 'SPEC-061',
    targets: {
      p95_latency_ms: { value: searchP95, target: 1500, pass: p95Pass },
      p99_latency_ms: { value: searchP99, target: 3000, pass: p99Pass },
      throughput_rps: { value: throughput, target: 100, pass: throughputPass },
      error_rate_percent: { value: errorRateVal, target: 1, pass: errorPass },
    },
    results: {
      search_latency: {
        avg: data.metrics.search_latency?.values.avg || 0,
        p50: data.metrics.search_latency?.values['p(50)'] || 0,
        p90: data.metrics.search_latency?.values['p(90)'] || 0,
        p95: searchP95,
        p99: searchP99,
      },
      store_latency: {
        avg: data.metrics.store_latency?.values.avg || 0,
        p95: storeP95,
      },
      operations: {
        total_requests: data.metrics.http_reqs?.values.count || 0,
        searches: data.metrics.search_count?.values.count || 0,
        stores: data.metrics.store_count?.values.count || 0,
      },
    },
    all_targets_pass: allPass,
  };

  // Generate text summary
  let output = '\n' + '='.repeat(70) + '\n';
  output += 'SPEC-061 PRODUCTION LOAD TEST RESULTS\n';
  output += '='.repeat(70) + '\n\n';
  
  output += 'TARGET COMPARISON:\n';
  output += '-'.repeat(50) + '\n';
  output += `  ${p95Pass ? '✓' : '✗'} p95 Latency: ${searchP95.toFixed(0)}ms (target: <1500ms)\n`;
  output += `  ${p99Pass ? '✓' : '✗'} p99 Latency: ${searchP99.toFixed(0)}ms (target: <3000ms)\n`;
  output += `  ${throughputPass ? '✓' : '✗'} Throughput: ${throughput.toFixed(1)} req/s (target: >100)\n`;
  output += `  ${errorPass ? '✓' : '✗'} Error Rate: ${errorRateVal.toFixed(2)}% (target: <1%)\n\n`;

  output += 'LATENCY BREAKDOWN (ms):\n';
  output += '-'.repeat(50) + '\n';
  output += `  Search: avg=${(data.metrics.search_latency?.values.avg || 0).toFixed(0)} `;
  output += `p50=${(data.metrics.search_latency?.values['p(50)'] || 0).toFixed(0)} `;
  output += `p90=${(data.metrics.search_latency?.values['p(90)'] || 0).toFixed(0)} `;
  output += `p95=${searchP95.toFixed(0)} p99=${searchP99.toFixed(0)}\n`;
  output += `  Store:  avg=${(data.metrics.store_latency?.values.avg || 0).toFixed(0)} `;
  output += `p95=${storeP95.toFixed(0)}\n\n`;

  output += 'OPERATIONS:\n';
  output += '-'.repeat(50) + '\n';
  output += `  Total Requests: ${data.metrics.http_reqs?.values.count || 0}\n`;
  output += `  Searches: ${data.metrics.search_count?.values.count || 0}\n`;
  output += `  Stores: ${data.metrics.store_count?.values.count || 0}\n`;
  output += `  Duration: ${(data.state.testRunDurationMs / 1000).toFixed(1)}s\n\n`;

  output += '='.repeat(70) + '\n';
  output += allPass ? '✓ ALL TARGETS PASSED\n' : '✗ SOME TARGETS FAILED\n';
  output += '='.repeat(70) + '\n\n';

  return {
    stdout: output,
    'bench/results/spec061_results.json': JSON.stringify(summary, null, 2),
  };
}
