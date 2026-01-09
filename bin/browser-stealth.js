#!/usr/bin/env node
/**
 * Browser Stealth - Puppeteer-based browser automation with stealth capabilities
 * 
 * Features:
 * - Cloudflare/Turnstile challenge handling
 * - UI testing and automation
 * - Screenshot and PDF generation
 * - Form interaction
 * - Cookie/session management
 * - Stealth mode to avoid bot detection
 * 
 * Usage: node browser-stealth.js <command> [options as JSON]
 * 
 * Commands:
 *   fetch     - Fetch URL with full JS execution
 *   screenshot - Take screenshot of page
 *   pdf       - Generate PDF of page
 *   evaluate  - Execute JavaScript on page
 *   interact  - Perform UI interactions (click, type, etc.)
 *   test      - Run UI test sequence
 */

const puppeteer = require('puppeteer-extra');
const StealthPlugin = require('puppeteer-extra-plugin-stealth');
const fs = require('fs');
const path = require('path');

// Apply stealth plugin with all evasions enabled
const stealth = StealthPlugin();
stealth.enabledEvasions.add('chrome.app');
stealth.enabledEvasions.add('chrome.csi');
stealth.enabledEvasions.add('chrome.loadTimes');
stealth.enabledEvasions.add('chrome.runtime');
puppeteer.use(stealth);

// Session storage directory for cookie persistence
const SESSION_DIR = process.env.MIMO_SESSION_DIR || '/tmp/mimo-browser-sessions';

// Find executable path - try system browsers first, then fall back to bundled
function findExecutablePath() {
  // Check environment variable first
  if (process.env.PUPPETEER_EXECUTABLE_PATH) {
    return process.env.PUPPETEER_EXECUTABLE_PATH;
  }

  // Common system browser paths
  const systemPaths = [
    '/usr/bin/chromium-browser',
    '/usr/bin/chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium'
  ];

  for (const path of systemPaths) {
    if (fs.existsSync(path)) {
      return path;
    }
  }

  // Return undefined to use Puppeteer's bundled browser
  return undefined;
}

/**
 * Get browser config with dynamic options
 */
function getBrowserConfig(options = {}) {
  const config = {
    headless: options.headed ? false : 'new',
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-accelerated-2d-canvas',
      '--no-first-run',
      '--no-zygote',
      '--disable-gpu',
      '--disable-background-networking',
      '--disable-default-apps',
      '--disable-extensions',
      '--disable-sync',
      '--disable-translate',
      '--hide-scrollbars',
      '--metrics-recording-only',
      '--mute-audio',
      '--safebrowsing-disable-auto-update',
      '--ignore-certificate-errors',
      '--ignore-ssl-errors',
      '--ignore-certificate-errors-spki-list',
      '--user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36'
    ],
    ignoreHTTPSErrors: true
  };

  // Add proxy support
  if (options.proxy) {
    config.args.push(`--proxy-server=${options.proxy}`);
  }

  // Add executable path if found
  const executablePath = findExecutablePath();
  if (executablePath) {
    config.executablePath = executablePath;
  }

  return config;
}

/**
 * Save session cookies to disk for persistence
 */
async function saveSession(page, sessionId) {
  if (!sessionId) return;

  try {
    if (!fs.existsSync(SESSION_DIR)) {
      fs.mkdirSync(SESSION_DIR, { recursive: true });
    }

    const cookies = await page.cookies();
    const sessionPath = path.join(SESSION_DIR, `${sessionId}.json`);
    fs.writeFileSync(sessionPath, JSON.stringify({
      cookies,
      savedAt: new Date().toISOString()
    }));

    return true;
  } catch (e) {
    console.error('[Session] Failed to save:', e.message);
    return false;
  }
}

/**
 * Load session cookies from disk
 */
async function loadSession(page, sessionId) {
  if (!sessionId) return false;

  try {
    const sessionPath = path.join(SESSION_DIR, `${sessionId}.json`);
    if (!fs.existsSync(sessionPath)) return false;

    const data = JSON.parse(fs.readFileSync(sessionPath));
    if (data.cookies && data.cookies.length > 0) {
      await page.setCookie(...data.cookies);
      return true;
    }
  } catch (e) {
    console.error('[Session] Failed to load:', e.message);
  }

  return false;
}

// Legacy config (replaced by getBrowserConfig but kept for compatibility)
const BROWSER_CONFIG = getBrowserConfig();

// Browser profiles matching Blink
const BROWSER_PROFILES = {
  chrome: {
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
    viewport: { width: 1920, height: 1080 },
    locale: 'en-US'
  },
  firefox: {
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:135.0) Gecko/20100101 Firefox/135.0',
    viewport: { width: 1920, height: 1080 },
    locale: 'en-US'
  },
  safari: {
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
    viewport: { width: 1920, height: 1080 },
    locale: 'en-US'
  },
  mobile: {
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    viewport: { width: 390, height: 844, isMobile: true, hasTouch: true },
    locale: 'en-US'
  }
};

/**
 * Wait for Cloudflare challenge to complete
 */
async function waitForCloudflare(page, timeout = 30000) {
  const startTime = Date.now();

  while (Date.now() - startTime < timeout) {
    const title = await page.title();
    const content = await page.content();

    // Check if we're past the challenge
    if (!title.toLowerCase().includes('just a moment') &&
      !title.toLowerCase().includes('checking your browser') &&
      !content.includes('cf-browser-verification') &&
      !content.includes('cf_chl_opt')) {
      return true;
    }

    // Wait a bit before checking again
    await new Promise(r => setTimeout(r, 1000));
  }

  return false;
}

/**
 * Setup page with stealth configurations
 */
async function setupPage(browser, profile = 'chrome', options = {}) {
  const page = await browser.newPage();
  const config = BROWSER_PROFILES[profile] || BROWSER_PROFILES.chrome;

  // Set user agent with optional randomization
  await page.setUserAgent(config.userAgent);

  // Set viewport with randomization to avoid fingerprinting (2025 technique)
  const baseWidth = config.viewport.width || 1920;
  const baseHeight = config.viewport.height || 1080;
  const viewportVariation = options.randomizeViewport !== false;

  await page.setViewport({
    width: viewportVariation ? Math.floor(baseWidth + (Math.random() - 0.5) * 100) : baseWidth,
    height: viewportVariation ? Math.floor(baseHeight + (Math.random() - 0.5) * 100) : baseHeight,
    ...config.viewport
  });

  // Set extra HTTP headers
  await page.setExtraHTTPHeaders({
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'gzip, deflate, br',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8'
  });

  // Emulate timezone
  await page.emulateTimezone('America/New_York');

  // Override webdriver detection and add advanced fingerprint evasion (2025 techniques)
  await page.evaluateOnNewDocument(() => {
    // Remove webdriver property
    Object.defineProperty(navigator, 'webdriver', {
      get: () => undefined
    });

    // Mock plugins
    Object.defineProperty(navigator, 'plugins', {
      get: () => [
        { name: 'Chrome PDF Plugin', filename: 'internal-pdf-viewer' },
        { name: 'Chrome PDF Viewer', filename: 'mhjfbmdgcfjbbpaeojofohoefgiehjai' },
        { name: 'Native Client', filename: 'internal-nacl-plugin' }
      ]
    });

    // Mock languages
    Object.defineProperty(navigator, 'languages', {
      get: () => ['en-US', 'en']
    });

    // Mock platform
    Object.defineProperty(navigator, 'platform', {
      get: () => 'Win32'
    });

    // Mock hardware concurrency (randomize slightly)
    Object.defineProperty(navigator, 'hardwareConcurrency', {
      get: () => [4, 8, 12, 16][Math.floor(Math.random() * 4)]
    });

    // Mock device memory (randomize)
    Object.defineProperty(navigator, 'deviceMemory', {
      get: () => [4, 8, 16][Math.floor(Math.random() * 3)]
    });

    // Chrome specific
    window.chrome = {
      runtime: {},
      loadTimes: function () { },
      csi: function () { },
      app: {}
    };

    // Permissions API mock
    const originalQuery = window.navigator.permissions.query;
    window.navigator.permissions.query = (parameters) => (
      parameters.name === 'notifications' ?
        Promise.resolve({ state: Notification.permission }) :
        originalQuery(parameters)
    );

    // Canvas fingerprint noise injection (2025 anti-fingerprint technique)
    const originalToDataURL = HTMLCanvasElement.prototype.toDataURL;
    HTMLCanvasElement.prototype.toDataURL = function (type) {
      if (type === 'image/png' && this.width > 0 && this.height > 0) {
        const ctx = this.getContext('2d');
        if (ctx) {
          // Add subtle noise that's invisible but changes fingerprint
          const imageData = ctx.getImageData(0, 0, this.width, this.height);
          for (let i = 0; i < imageData.data.length; i += 4) {
            // Add tiny random variations (imperceptible but breaks fingerprint)
            imageData.data[i] = imageData.data[i] ^ (Math.random() > 0.99 ? 1 : 0);
          }
          ctx.putImageData(imageData, 0, 0);
        }
      }
      return originalToDataURL.apply(this, arguments);
    };

    // WebGL renderer spoofing
    const getParameter = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function (parameter) {
      // UNMASKED_VENDOR_WEBGL
      if (parameter === 37445) {
        return 'Intel Inc.';
      }
      // UNMASKED_RENDERER_WEBGL
      if (parameter === 37446) {
        return 'Intel Iris OpenGL Engine';
      }
      return getParameter.apply(this, arguments);
    };
  });

  return page;
}

/**
 * Fetch URL with full browser capabilities
 * 
 * 2025 Enhanced Options:
 * - proxy: Proxy URL (http://user:pass@host:port) 
 * - headed: Run with visible browser for hard targets
 * - sessionId: Save/load cookies for this session
 */
async function fetchUrl(options) {
  const {
    url,
    profile = 'chrome',
    timeout = 30000,
    waitForSelector = null,
    waitForNavigation = true,
    cookies = [],
    headers = {},
    waitForChallenge = true,
    // New 2025 options
    proxy = null,
    headed = false,
    sessionId = null
  } = options;

  let browser;
  try {
    // Use dynamic config with options
    const browserConfig = getBrowserConfig({ proxy, headed });
    browser = await puppeteer.launch(browserConfig);
    const page = await setupPage(browser, profile, { randomizeViewport: true });

    // Load saved session if available
    if (sessionId) {
      await loadSession(page, sessionId);
    }

    // Set cookies if provided (additional to session)
    if (cookies.length > 0) {
      await page.setCookie(...cookies);
    }

    // Set extra headers
    if (Object.keys(headers).length > 0) {
      await page.setExtraHTTPHeaders(headers);
    }

    // Navigate to URL
    const response = await page.goto(url, {
      waitUntil: waitForNavigation ? 'networkidle2' : 'domcontentloaded',
      timeout
    });

    // Wait for Cloudflare challenge if detected
    if (waitForChallenge) {
      await waitForCloudflare(page, timeout);
    }

    // Wait for specific selector if provided
    if (waitForSelector) {
      await page.waitForSelector(waitForSelector, { timeout });
    }

    // Get response data
    const status = response ? response.status() : 200;
    const responseHeaders = response ? response.headers() : {};
    const content = await page.content();
    const title = await page.title();
    const finalUrl = page.url();
    const pageCookies = await page.cookies();

    // Save session for future requests
    if (sessionId) {
      await saveSession(page, sessionId);
    }

    return {
      success: true,
      data: {
        status,
        url: finalUrl,
        title,
        body: content,
        headers: responseHeaders,
        cookies: pageCookies,
        bodySize: content.length,
        // Metadata about stealth features used
        stealth: {
          proxy: !!proxy,
          headed,
          sessionPersisted: !!sessionId,
          viewportRandomized: true,
          canvasNoise: true,
          webglSpoofed: true
        }
      }
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

/**
 * Take screenshot of page
 */
async function takeScreenshot(options) {
  const {
    url,
    profile = 'chrome',
    timeout = 30000,
    fullPage = true,
    type = 'png',
    quality = 80,
    selector = null,
    waitForSelector = null
  } = options;

  let browser;
  try {
    browser = await puppeteer.launch(BROWSER_CONFIG);
    const page = await setupPage(browser, profile);

    await page.goto(url, {
      waitUntil: 'networkidle2',
      timeout
    });

    // Wait for challenge
    await waitForCloudflare(page, timeout);

    // Wait for selector if provided
    if (waitForSelector) {
      await page.waitForSelector(waitForSelector, { timeout });
    }

    // Screenshot options
    const screenshotOptions = {
      fullPage: selector ? false : fullPage,
      type,
      encoding: 'base64'
    };

    if (type === 'jpeg') {
      screenshotOptions.quality = quality;
    }

    let screenshot;
    if (selector) {
      const element = await page.$(selector);
      if (element) {
        screenshot = await element.screenshot(screenshotOptions);
      } else {
        throw new Error(`Selector not found: ${selector}`);
      }
    } else {
      screenshot = await page.screenshot(screenshotOptions);
    }

    return {
      success: true,
      data: {
        screenshot,
        type,
        url: page.url(),
        title: await page.title()
      }
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

/**
 * Generate PDF of page
 */
async function generatePdf(options) {
  const {
    url,
    profile = 'chrome',
    timeout = 30000,
    format = 'A4',
    printBackground = true,
    margin = { top: '1cm', right: '1cm', bottom: '1cm', left: '1cm' }
  } = options;

  let browser;
  try {
    browser = await puppeteer.launch(BROWSER_CONFIG);
    const page = await setupPage(browser, profile);

    await page.goto(url, {
      waitUntil: 'networkidle2',
      timeout
    });

    await waitForCloudflare(page, timeout);

    const pdf = await page.pdf({
      format,
      printBackground,
      margin,
      encoding: 'base64'
    });

    return {
      success: true,
      data: {
        pdf: pdf.toString('base64'),
        url: page.url(),
        title: await page.title()
      }
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

/**
 * Execute JavaScript on page
 */
async function evaluateScript(options) {
  const {
    url,
    script,
    profile = 'chrome',
    timeout = 30000,
    waitForSelector = null
  } = options;

  let browser;
  try {
    browser = await puppeteer.launch(BROWSER_CONFIG);
    const page = await setupPage(browser, profile);

    await page.goto(url, {
      waitUntil: 'networkidle2',
      timeout
    });

    await waitForCloudflare(page, timeout);

    if (waitForSelector) {
      await page.waitForSelector(waitForSelector, { timeout });
    }

    // Execute the script
    const result = await page.evaluate(script);

    return {
      success: true,
      data: {
        result,
        url: page.url(),
        title: await page.title()
      }
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

/**
 * Perform UI interactions
 */
async function interact(options) {
  const {
    url,
    actions = [],
    profile = 'chrome',
    timeout = 30000
  } = options;

  let browser;
  try {
    browser = await puppeteer.launch(BROWSER_CONFIG);
    const page = await setupPage(browser, profile);

    await page.goto(url, {
      waitUntil: 'networkidle2',
      timeout
    });

    await waitForCloudflare(page, timeout);

    const results = [];

    // Execute each action
    for (const action of actions) {
      try {
        let actionResult = { action: action.type, success: true };

        switch (action.type) {
          case 'click':
            await page.click(action.selector);
            actionResult.selector = action.selector;
            break;

          case 'type':
            await page.type(action.selector, action.text, { delay: action.delay || 50 });
            actionResult.selector = action.selector;
            break;

          case 'select':
            await page.select(action.selector, action.value);
            actionResult.selector = action.selector;
            break;

          case 'wait':
            if (action.selector) {
              await page.waitForSelector(action.selector, { timeout: action.timeout || timeout });
            } else if (action.ms) {
              await new Promise(r => setTimeout(r, action.ms));
            }
            break;

          case 'scroll':
            await page.evaluate((x, y) => window.scrollTo(x, y), action.x || 0, action.y || 0);
            break;

          case 'hover':
            await page.hover(action.selector);
            actionResult.selector = action.selector;
            break;

          case 'focus':
            await page.focus(action.selector);
            actionResult.selector = action.selector;
            break;

          case 'press':
            await page.keyboard.press(action.key);
            actionResult.key = action.key;
            break;

          case 'screenshot':
            const screenshot = await page.screenshot({ encoding: 'base64', fullPage: action.fullPage });
            actionResult.screenshot = screenshot;
            break;

          case 'evaluate':
            actionResult.result = await page.evaluate(action.script);
            break;

          case 'waitForNavigation':
            await page.waitForNavigation({ timeout: action.timeout || timeout });
            break;

          default:
            actionResult.success = false;
            actionResult.error = `Unknown action type: ${action.type}`;
        }

        results.push(actionResult);
      } catch (actionError) {
        results.push({
          action: action.type,
          success: false,
          error: actionError.message
        });

        if (action.required !== false) {
          break; // Stop on required action failure
        }
      }
    }

    return {
      success: true,
      data: {
        results,
        url: page.url(),
        title: await page.title(),
        content: await page.content()
      }
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

/**
 * Run UI test sequence
 */
async function runTest(options) {
  const {
    url,
    tests = [],
    profile = 'chrome',
    timeout = 30000
  } = options;

  let browser;
  try {
    browser = await puppeteer.launch(BROWSER_CONFIG);
    const page = await setupPage(browser, profile);

    await page.goto(url, {
      waitUntil: 'networkidle2',
      timeout
    });

    await waitForCloudflare(page, timeout);

    const testResults = [];

    for (const test of tests) {
      const testResult = {
        name: test.name,
        passed: false,
        assertions: []
      };

      try {
        // Execute test actions if any
        if (test.actions) {
          for (const action of test.actions) {
            switch (action.type) {
              case 'click':
                await page.click(action.selector);
                break;
              case 'type':
                await page.type(action.selector, action.text);
                break;
              case 'wait':
                await page.waitForSelector(action.selector, { timeout: action.timeout || 5000 });
                break;
              case 'navigate':
                await page.goto(action.url, { waitUntil: 'networkidle2' });
                break;
            }
          }
        }

        // Run assertions
        for (const assertion of test.assertions || []) {
          const assertionResult = { type: assertion.type, passed: false };

          switch (assertion.type) {
            case 'exists':
              const exists = await page.$(assertion.selector) !== null;
              assertionResult.passed = exists === (assertion.expected !== false);
              assertionResult.selector = assertion.selector;
              break;

            case 'text':
              const text = await page.$eval(assertion.selector, el => el.textContent);
              assertionResult.passed = assertion.contains
                ? text.includes(assertion.contains)
                : text === assertion.expected;
              assertionResult.actual = text;
              break;

            case 'value':
              const value = await page.$eval(assertion.selector, el => el.value);
              assertionResult.passed = value === assertion.expected;
              assertionResult.actual = value;
              break;

            case 'visible':
              const visible = await page.$eval(assertion.selector, el => {
                const style = window.getComputedStyle(el);
                return style.display !== 'none' && style.visibility !== 'hidden';
              });
              assertionResult.passed = visible === (assertion.expected !== false);
              break;

            case 'url':
              const currentUrl = page.url();
              assertionResult.passed = assertion.contains
                ? currentUrl.includes(assertion.contains)
                : currentUrl === assertion.expected;
              assertionResult.actual = currentUrl;
              break;

            case 'title':
              const title = await page.title();
              assertionResult.passed = assertion.contains
                ? title.includes(assertion.contains)
                : title === assertion.expected;
              assertionResult.actual = title;
              break;

            case 'count':
              const elements = await page.$$(assertion.selector);
              assertionResult.passed = elements.length === assertion.expected;
              assertionResult.actual = elements.length;
              break;
          }

          testResult.assertions.push(assertionResult);
        }

        testResult.passed = testResult.assertions.every(a => a.passed);
      } catch (testError) {
        testResult.error = testError.message;
      }

      testResults.push(testResult);
    }

    const allPassed = testResults.every(t => t.passed);

    return {
      success: true,
      data: {
        passed: allPassed,
        total: testResults.length,
        passed_count: testResults.filter(t => t.passed).length,
        failed_count: testResults.filter(t => !t.passed).length,
        tests: testResults,
        url: page.url()
      }
    };
  } catch (error) {
    return {
      success: false,
      error: error.message
    };
  } finally {
    if (browser) {
      await browser.close();
    }
  }
}

// Main entry point
async function main() {
  const args = process.argv.slice(2);

  if (args.length < 1) {
    console.error(JSON.stringify({
      success: false,
      error: 'Usage: browser-stealth.js <command> [options as JSON]'
    }));
    process.exit(1);
  }

  const command = args[0];
  let options = {};

  if (args.length > 1) {
    try {
      options = JSON.parse(args[1]);
    } catch (e) {
      console.error(JSON.stringify({
        success: false,
        error: `Invalid JSON options: ${e.message}`
      }));
      process.exit(1);
    }
  }

  let result;

  switch (command) {
    case 'fetch':
      result = await fetchUrl(options);
      break;
    case 'screenshot':
      result = await takeScreenshot(options);
      break;
    case 'pdf':
      result = await generatePdf(options);
      break;
    case 'evaluate':
      result = await evaluateScript(options);
      break;
    case 'interact':
      result = await interact(options);
      break;
    case 'test':
      result = await runTest(options);
      break;
    default:
      result = {
        success: false,
        error: `Unknown command: ${command}. Available: fetch, screenshot, pdf, evaluate, interact, test`
      };
  }

  console.log(JSON.stringify(result));
}

main().catch(error => {
  console.error(JSON.stringify({
    success: false,
    error: error.message
  }));
  process.exit(1);
});
