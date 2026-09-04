import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, get, IncomingHttpHeaders, OutgoingHttpHeaders } from 'node:http';
import { AddressInfo } from 'node:net';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { AngularSsrEngine, AngularSsrResponseWriter, createExpressApp } from './server-app';

describe('SSR Express server', () => {
  const requiredEnvNames = [
    'PORT',
    'SSR_API_ORIGIN',
    'SSR_PUBLIC_ORIGIN',
    'APP_URL_SCHEMA',
    'APP_DOMAIN',
  ];
  let originalEnv: NodeJS.ProcessEnv;

  beforeEach(() => {
    originalEnv = { ...process.env };
    for (const name of requiredEnvNames) {
      delete process.env[name];
    }
  });

  afterEach(() => {
    jest.restoreAllMocks();
    process.env = originalEnv;
  });

  it('serves healthz without reading SSR environment or calling Angular', async () => {
    const angularApp: AngularSsrEngine = {
      handle: jest.fn().mockRejectedValue(new Error('Angular should not handle healthz')),
    };
    const responseWriter: AngularSsrResponseWriter = jest.fn();
    const app = createExpressApp({
      browserDistFolder: '/tmp/non-existent-browser-dist',
      angularApp,
      responseWriter,
    });
    const server = createServer(app);

    try {
      await new Promise<void>((resolve) => {
        server.listen(0, '127.0.0.1', resolve);
      });
      const address = server.address() as AddressInfo;
      const response = await request(`http://127.0.0.1:${address.port}/healthz`);

      expect(response.status).toBe(200);
      expect(response.body).toBe('');
      expect(response.headers['x-powered-by']).toBeUndefined();
      expect(angularApp.handle).not.toHaveBeenCalled();
      expect(responseWriter).not.toHaveBeenCalled();
    } finally {
      await new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      });
    }
  });

  it('runs public SEO preflight without returning a Promise-like Express handler', async () => {
    process.env['SSR_API_ORIGIN'] = 'http://backend.internal';
    process.env['SSR_PUBLIC_ORIGIN'] = 'https://example.com';
    const originalFetch = globalThis.fetch;
    const fetchSpy = jest.fn<typeof fetch>().mockResolvedValue({
      ok: true,
      status: 200,
      body: {
        cancel: jest.fn().mockResolvedValue(undefined),
      },
    } as unknown as Response);
    Object.defineProperty(globalThis, 'fetch', {
      configurable: true,
      writable: true,
      value: fetchSpy,
    });
    const angularResponse = {
      status: 200,
    } as Response;
    const restoreFetch = (): void => {
      if (originalFetch === undefined) {
        Reflect.deleteProperty(globalThis, 'fetch');
        return;
      }
      Object.defineProperty(globalThis, 'fetch', {
        configurable: true,
        writable: true,
        value: originalFetch,
      });
    };
    const stderrWrite = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    const angularApp: AngularSsrEngine = {
      handle: jest.fn().mockResolvedValue(angularResponse),
    };
    const responseWriter: AngularSsrResponseWriter = (response, res) => {
      res.status(response.status).type('text/plain').send('rendered');
    };
    const app = createExpressApp({
      browserDistFolder: '/tmp/non-existent-browser-dist',
      angularApp,
      responseWriter,
    });
    const server = createServer(app);

    try {
      await new Promise<void>((resolve) => {
        server.listen(0, '127.0.0.1', resolve);
      });
      const address = server.address() as AddressInfo;
      const response = await request(`http://127.0.0.1:${address.port}/ru/articles/typed-articles`);
      const stderrOutput = stderrWrite.mock.calls.map(([chunk]) => String(chunk)).join('\n');

      expect(response.status).toBe(200);
      expect(response.body).toBe('rendered');
      expect(fetchSpy).toHaveBeenCalledWith(
        new URL('http://backend.internal/api/articles/detail/typed-articles?language=ru'),
        {
          method: 'GET',
          headers: {
            Accept: 'application/json',
          },
        },
      );
      expect(angularApp.handle).toHaveBeenCalled();
      expect(stderrOutput).not.toContain('handlers that are Promise-like are deprecated');
    } finally {
      restoreFetch();
      await closeServer(server);
    }
  });

  it('replaces SSR CSP nonce placeholders with the edge nonce header', async () => {
    const restoreFetchPrimitives = installFetchResponseTestPrimitives();
    const nonce = '0123456789abcdef0123456789abcdef';
    const angularResponse = new Response(
      '<!doctype html><html><head><script nonce="__CSP_NONCE__"></script></head>' +
        '<body><app-root ngCspNonce="__CSP_NONCE__"></app-root></body></html>',
      {
        status: 200,
        headers: {
          'content-type': 'text/html',
          'content-length': '999',
        },
      },
    );
    const angularApp: AngularSsrEngine = {
      handle: jest.fn().mockResolvedValue(angularResponse),
    };
    const responseWriter: AngularSsrResponseWriter = async (response, res) => {
      res
        .status(response.status)
        .type('html')
        .send({
          body: await response.text(),
          contentLength: response.headers.get('content-length'),
        });
    };
    const app = createExpressApp({
      browserDistFolder: '/tmp/non-existent-browser-dist',
      angularApp,
      responseWriter,
    });
    const server = createServer(app);

    try {
      await new Promise<void>((resolve) => {
        server.listen(0, '127.0.0.1', resolve);
      });
      const address = server.address() as AddressInfo;
      const response = await request(`http://127.0.0.1:${address.port}/`, {
        'x-csp-nonce': nonce,
      });
      const payload = JSON.parse(response.body) as { body: string; contentLength: string | null };

      expect(payload.body).toContain(`nonce="${nonce}"`);
      expect(payload.body).toContain(`ngCspNonce="${nonce}"`);
      expect(payload.body).not.toContain('__CSP_NONCE__');
      expect(payload.contentLength).toBeNull();
    } finally {
      restoreFetchPrimitives();
      await closeServer(server);
    }
  });

  it('serves hashed JavaScript and CSS with immutable cache headers', async () => {
    const browserDistFolder = mkdtempSync(join(tmpdir(), 'competency-trainer-browser-dist-'));
    writeFileSync(join(browserDistFolder, 'main-ABCDEFGH.js'), 'console.log("ok");');
    writeFileSync(join(browserDistFolder, 'styles-ABCDEFGH.css'), 'body{}');
    const angularApp: AngularSsrEngine = {
      handle: jest.fn().mockRejectedValue(new Error('Angular should not handle static assets')),
    };
    const responseWriter: AngularSsrResponseWriter = jest.fn();
    const app = createExpressApp({
      browserDistFolder,
      angularApp,
      responseWriter,
    });
    const server = createServer(app);

    try {
      await new Promise<void>((resolve) => {
        server.listen(0, '127.0.0.1', resolve);
      });
      const address = server.address() as AddressInfo;

      const scriptResponse = await request(`http://127.0.0.1:${address.port}/main-ABCDEFGH.js`);
      const styleResponse = await request(`http://127.0.0.1:${address.port}/styles-ABCDEFGH.css`);

      expect(scriptResponse.headers['cache-control']).toBe('public, max-age=31536000, immutable');
      expect(styleResponse.headers['cache-control']).toBe('public, max-age=31536000, immutable');
      expect(angularApp.handle).not.toHaveBeenCalled();
      expect(responseWriter).not.toHaveBeenCalled();
    } finally {
      await closeServer(server);
      rmSync(browserDistFolder, { recursive: true, force: true });
    }
  });

  it('serves stable public asset filenames with bounded non-immutable cache headers', async () => {
    const browserDistFolder = mkdtempSync(join(tmpdir(), 'competency-trainer-browser-dist-'));
    writeFileSync(join(browserDistFolder, 'logo-192x192.webp'), 'image');
    const angularApp: AngularSsrEngine = {
      handle: jest.fn().mockRejectedValue(new Error('Angular should not handle static assets')),
    };
    const responseWriter: AngularSsrResponseWriter = jest.fn();
    const app = createExpressApp({
      browserDistFolder,
      angularApp,
      responseWriter,
    });
    const server = createServer(app);

    try {
      await new Promise<void>((resolve) => {
        server.listen(0, '127.0.0.1', resolve);
      });
      const address = server.address() as AddressInfo;
      const response = await request(`http://127.0.0.1:${address.port}/logo-192x192.webp`);

      expect(response.headers['cache-control']).toBe('public, max-age=15552000');
      expect(angularApp.handle).not.toHaveBeenCalled();
      expect(responseWriter).not.toHaveBeenCalled();
    } finally {
      await closeServer(server);
      rmSync(browserDistFolder, { recursive: true, force: true });
    }
  });
});

interface HttpResponse {
  readonly status: number | undefined;
  readonly body: string;
  readonly headers: IncomingHttpHeaders;
}

function request(url: string, headers: OutgoingHttpHeaders = {}): Promise<HttpResponse> {
  return new Promise((resolve, reject) => {
    get(url, { headers }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (chunk: string) => {
        body += chunk;
      });
      response.on('end', () => {
        resolve({ status: response.statusCode, body, headers: response.headers });
      });
    }).on('error', reject);
  });
}

function closeServer(server: ReturnType<typeof createServer>): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

function installFetchResponseTestPrimitives(): () => void {
  const originalResponse = globalThis.Response;
  const originalHeaders = globalThis.Headers;
  const hadResponse = Object.prototype.hasOwnProperty.call(globalThis, 'Response');
  const hadHeaders = Object.prototype.hasOwnProperty.call(globalThis, 'Headers');

  Object.defineProperty(globalThis, 'Headers', {
    configurable: true,
    writable: true,
    value: TestHeaders,
  });
  Object.defineProperty(globalThis, 'Response', {
    configurable: true,
    writable: true,
    value: TestResponse,
  });

  return () => {
    restoreGlobal('Response', hadResponse, originalResponse);
    restoreGlobal('Headers', hadHeaders, originalHeaders);
  };
}

function restoreGlobal(name: 'Headers' | 'Response', existed: boolean, value: unknown): void {
  if (!existed) {
    Reflect.deleteProperty(globalThis, name);
    return;
  }
  Object.defineProperty(globalThis, name, {
    configurable: true,
    writable: true,
    value,
  });
}

class TestHeaders {
  private readonly values = new Map<string, string>();

  constructor(init?: HeadersInit | TestHeaders) {
    if (init instanceof TestHeaders) {
      init.forEach((value, key) => this.set(key, value));
      return;
    }
    if (Array.isArray(init)) {
      for (const [key, value] of init) {
        this.set(key, value);
      }
      return;
    }
    if (init) {
      for (const [key, value] of Object.entries(init)) {
        this.set(key, value);
      }
    }
  }

  get(name: string): string | null {
    return this.values.get(name.toLowerCase()) ?? null;
  }

  set(name: string, value: string): void {
    this.values.set(name.toLowerCase(), value);
  }

  delete(name: string): void {
    this.values.delete(name.toLowerCase());
  }

  forEach(callback: (value: string, key: string) => void): void {
    for (const [key, value] of this.values) {
      callback(value, key);
    }
  }
}

class TestResponse {
  readonly headers: TestHeaders;
  readonly status: number;
  readonly statusText: string;

  constructor(
    private readonly body: string,
    init: ResponseInit = {},
  ) {
    this.headers = new TestHeaders(init.headers);
    this.status = init.status ?? 200;
    this.statusText = init.statusText ?? '';
  }

  async text(): Promise<string> {
    return this.body;
  }
}
