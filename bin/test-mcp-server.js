#!/usr/bin/env node
// Minimal MCP server for testing VS Code integration
const readline = require('readline');

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on('line', (line) => {
  try {
    const req = JSON.parse(line);
    
    if (req.method === 'initialize') {
      const response = {
        jsonrpc: '2.0',
        id: req.id,
        result: {
          protocolVersion: '2024-11-05',
          serverInfo: { name: 'test-mcp', version: '1.0.0' },
          capabilities: { tools: { listChanged: true } }
        }
      };
      console.log(JSON.stringify(response));
    } else if (req.method === 'notifications/initialized') {
      // No response needed
    } else if (req.method === 'tools/list') {
      const response = {
        jsonrpc: '2.0',
        id: req.id,
        result: {
          tools: [
            {
              name: 'test_echo',
              description: 'Echo back the input message',
              inputSchema: {
                type: 'object',
                properties: {
                  message: { type: 'string', description: 'Message to echo' }
                },
                required: ['message']
              }
            },
            {
              name: 'test_add',
              description: 'Add two numbers',
              inputSchema: {
                type: 'object',
                properties: {
                  a: { type: 'number', description: 'First number' },
                  b: { type: 'number', description: 'Second number' }
                },
                required: ['a', 'b']
              }
            }
          ]
        }
      };
      console.log(JSON.stringify(response));
    } else if (req.method === 'tools/call') {
      const { name, arguments: args } = req.params;
      let result;
      
      if (name === 'test_echo') {
        result = { content: [{ type: 'text', text: args.message }] };
      } else if (name === 'test_add') {
        result = { content: [{ type: 'text', text: String(args.a + args.b) }] };
      } else {
        console.log(JSON.stringify({
          jsonrpc: '2.0',
          id: req.id,
          error: { code: -32601, message: `Unknown tool: ${name}` }
        }));
        return;
      }
      
      console.log(JSON.stringify({ jsonrpc: '2.0', id: req.id, result }));
    } else {
      // Unknown method
      if (req.id) {
        console.log(JSON.stringify({
          jsonrpc: '2.0',
          id: req.id,
          error: { code: -32601, message: `Method not found: ${req.method}` }
        }));
      }
    }
  } catch (e) {
    console.log(JSON.stringify({
      jsonrpc: '2.0',
      id: null,
      error: { code: -32700, message: 'Parse error' }
    }));
  }
});

// Keep process alive
process.stdin.resume();
