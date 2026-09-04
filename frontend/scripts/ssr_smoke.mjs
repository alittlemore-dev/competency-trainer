import { startSsrFixture } from './ssr_mock_app.mjs';

let failure = null;
const fixture = await startSsrFixture();
const { frontendPort, requests } = fixture;

try {
  await assertDiscoveryEndpoints(frontendPort);
  await assertBrowserApiProxy(frontendPort);
  await assertFixtureCover(frontendPort);
  await assertBrowserAnalyticsProxy(frontendPort);
  await assertSiteBuildCaseStudyHtml(frontendPort, requests);
  await assertUpdatesHtml(frontendPort, requests);
  await assertPublishedArticleHtml(frontendPort, requests);
  await assertMissingArticleNoindex(frontendPort, requests);
  await assertPublishedMatrixQuestionHtml(frontendPort, requests);
  await assertMissingMatrixQuestionNoindex(frontendPort, requests);
  console.log(`SSR smoke passed with ${requests.length} backend requests.`);
  console.log(requests.join('\n'));
} catch (error) {
  failure = error;
  console.error(error instanceof Error ? error.message : String(error));
} finally {
  await fixture.close();
}

if (failure !== null) {
  process.exitCode = 1;
}

async function assertDiscoveryEndpoints(frontendPort) {
  const origin = `http://127.0.0.1:${frontendPort}`;
  const robotsResponse = await fetch(`${origin}/robots.txt`);
  const robotsText = await robotsResponse.text();
  const sitemapResponse = await fetch(`${origin}/sitemap.xml`);
  const sitemapText = await sitemapResponse.text();
  const expected = [
    ['robots status 200', robotsResponse.status === 200],
    [
      'robots text content type',
      robotsResponse.headers.get('content-type')?.startsWith('text/plain'),
    ],
    ['robots gzip', robotsResponse.headers.get('content-encoding') === 'gzip'],
    ['robots user agent', robotsText.includes('User-agent: *\n')],
    ['robots sitemap origin', robotsText.includes(`Sitemap: ${origin}/sitemap.xml\n`)],
    ['sitemap status 200', sitemapResponse.status === 200],
    [
      'sitemap xml content type',
      sitemapResponse.headers.get('content-type')?.startsWith('application/xml'),
    ],
    ['sitemap gzip', sitemapResponse.headers.get('content-encoding') === 'gzip'],
    [
      'sitemap urlset',
      sitemapText.includes('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"'),
    ],
    ['sitemap canonical route', sitemapText.includes(`${origin}/ru/how-this-site-is-built`)],
    ['sitemap updates route', sitemapText.includes(`${origin}/ru/updates`)],
    ['sitemap excludes removed about page', !sitemapText.includes('/about-me')],
  ];
  assertExpected(expected, `${robotsText}\n${sitemapText}`, 'LHCI discovery endpoints');
}

async function assertBrowserApiProxy(frontendPort) {
  const response = await fetch(`http://127.0.0.1:${frontendPort}/api/i18n/languages`);
  const contentType = response.headers.get('content-type') ?? '';
  const body = await response.text();
  const expected = [
    ['status 200', response.status === 200],
    ['json content type', contentType.startsWith('application/json')],
    ['language payload', body.includes('"defaultLanguage":"ru"')],
  ];
  assertExpected(expected, body, 'browser API proxy');
}

async function assertFixtureCover(frontendPort) {
  const response = await fetch(
    `http://127.0.0.1:${frontendPort}/api/fixtures/article-cover.svg`,
  );
  const contentType = response.headers.get('content-type') ?? '';
  const cacheControl = response.headers.get('cache-control') ?? '';
  const body = await response.text();
  const expected = [
    ['status 200', response.status === 200],
    ['image content type', contentType.startsWith('image/svg+xml')],
    ['immutable cache', cacheControl === 'public, max-age=31536000, immutable'],
    ['16:9 dimensions', body.includes('viewBox="0 0 1600 900"')],
  ];
  assertExpected(expected, body, 'fixture article cover');
}

async function assertBrowserAnalyticsProxy(frontendPort) {
  const response = await fetch(
    `http://127.0.0.1:${frontendPort}/api/articles/detail/typed-articles/analytics/view?language=ru`,
    { method: 'POST' },
  );
  const body = await response.text();
  const expected = [
    ['status 204', response.status === 204],
    ['empty body', body.length === 0],
  ];
  assertExpected(expected, body, 'browser analytics proxy');
}

async function assertSiteBuildCaseStudyHtml(frontendPort, requests) {
  const requestStart = requests.length;
  const response = await fetch(`http://127.0.0.1:${frontendPort}/ru/how-this-site-is-built`);
  const html = await response.text();
  const pageRequests = requests.slice(requestStart);
  const expected = [
    ['status 200', response.status === 200],
    ['title', html.includes('<title>How this site is built</title>')],
    [
      'hero',
      html.includes('Engineering case study of a production-minded portfolio and articles site.'),
    ],
    ['architecture', html.includes('Angular hybrid SSR/CSR and backend-driven i18n.')],
    [
      'source code CTA',
      html.includes('href="https://github.com/alittlemore-dev/competency-trainer"'),
    ],
    [
      'canonical',
      html.includes(`href="http://127.0.0.1:${frontendPort}/ru/how-this-site-is-built"`),
    ],
    ['hreflang ru', html.includes('hreflang="ru"')],
    ['hreflang en', html.includes('hreflang="en"')],
    ['no API request beyond i18n', pageRequests.every((entry) => !entry.includes('/api/articles/'))],
    ['no noindex on case study', !html.includes('name="robots" content="noindex')],
  ];
  assertExpected(expected, html, 'site-build case study SSR');
}

async function assertUpdatesHtml(frontendPort, requests) {
  const requestStart = requests.length;
  const response = await fetch(`http://127.0.0.1:${frontendPort}/ru/updates`);
  const html = await response.text();
  const pageRequests = requests.slice(requestStart);
  const expected = [
    ['status 200', response.status === 200],
    ['title', html.includes('<title>Updates</title>')],
    ['hero', html.includes('Major changes to the portfolio and articles site')],
    ['month', html.includes('Июль 2026')],
    ['history month', html.includes('Сентябрь 2024')],
    ['milestone', html.includes('Публичный SEO-контур вышел в SSR')],
    ['canonical', html.includes(`href="http://127.0.0.1:${frontendPort}/ru/updates"`)],
    ['hreflang ru', html.includes('hreflang="ru"')],
    ['hreflang en', html.includes('hreflang="en"')],
    ['no article API request', pageRequests.every((entry) => !entry.includes('/api/articles/'))],
    [
      'no matrix API request',
      pageRequests.every((entry) => !entry.includes('/api/competency-matrix/')),
    ],
    ['no noindex on updates', !html.includes('name="robots" content="noindex')],
  ];
  assertExpected(expected, html, 'updates SSR');
}

async function assertPublishedArticleHtml(frontendPort, requests) {
  const requestStart = requests.length;
  const origin = `http://127.0.0.1:${frontendPort}`;
  const response = await fetch(`${origin}/ru/articles/typed-articles`);
  const html = await response.text();
  const pageRequests = requests.slice(requestStart);
  const expected = [
    ['status 200', response.status === 200],
    ['article title', html.includes('<title>SEO Typed articles RU</title>')],
    ['article body', html.includes('Rendered SSR article body')],
    ['canonical', html.includes(`href="http://127.0.0.1:${frontendPort}/ru/articles/typed-articles"`)],
    ['hreflang ru', html.includes('hreflang="ru"')],
    ['hreflang en', html.includes('hreflang="en"')],
    ['og type article', html.includes('property="og:type" content="article"')],
    [
      'og image',
      html.includes(
        `property="og:image" content="${origin}/api/fixtures/article-cover.svg"`,
      ),
    ],
    ['json-ld', html.includes('"@type":"BlogPosting"')],
    ['json-ld headline', html.includes('"headline":"SEO Typed articles RU"')],
    [
      'wiki link to matrix localized',
      html.includes('href="/ru/competency-matrix/questions/how-to-write-function"'),
    ],
    ['article code language', html.includes('class="language-ts"')],
    ['article code syntax token', html.includes('class="token keyword">const</span>')],
    ['no noindex on published article', !html.includes('name="robots" content="noindex')],
    ['no analytics request', pageRequests.every((entry) => !entry.includes('/analytics/'))],
    ['no reaction request', pageRequests.every((entry) => !entry.includes('/reaction'))],
  ];
  assertExpected(expected, html, 'published article SSR');
}

async function assertPublishedMatrixQuestionHtml(frontendPort, requests) {
  const requestStart = requests.length;
  const response = await fetch(
    `http://127.0.0.1:${frontendPort}/ru/competency-matrix/questions/how-to-write-function`,
  );
  const html = await response.text();
  const pageRequests = requests.slice(requestStart);
  const expected = [
    ['status 200', response.status === 200],
    ['matrix question title', html.includes('<title>Как написать функцию?</title>')],
    ['matrix question body', html.includes('Rendered SSR matrix answer')],
    [
      'canonical',
      html.includes(
        `href="http://127.0.0.1:${frontendPort}/ru/competency-matrix/questions/how-to-write-function"`,
      ),
    ],
    ['hreflang ru', html.includes('hreflang="ru"')],
    ['hreflang en', html.includes('hreflang="en"')],
    ['json-ld faq', html.includes('"@type":"FAQPage"')],
    ['json-ld question', html.includes('"name":"Как написать функцию?"')],
    ['wiki link to article localized', html.includes('href="/ru/articles/typed-articles"')],
    ['matrix code language', html.includes('class="language-python"')],
    ['matrix code syntax token', html.includes('class="token keyword">def</span>')],
    ['no noindex on published matrix question', !html.includes('name="robots" content="noindex')],
    [
      'matrix public detail preflight',
      hasRequest(
        pageRequests,
        '/api/competency-matrix/items/public/how-to-write-function',
        'language=ru',
      ),
    ],
    ['no analytics request', pageRequests.every((entry) => !entry.includes('/analytics/'))],
    ['no reaction request', pageRequests.every((entry) => !entry.includes('/reaction'))],
  ];
  assertExpected(expected, html, 'published matrix question SSR');
}

async function assertMissingArticleNoindex(frontendPort, requests) {
  const requestStart = requests.length;
  const response = await fetch(`http://127.0.0.1:${frontendPort}/ru/articles/missing-article`);
  const html = await response.text();
  const pageRequests = requests.slice(requestStart);
  const expected = [
    ['status 404', response.status === 404],
    ['noindex', html.includes('<meta name="robots" content="noindex, follow">')],
    [
      'canonical',
      html.includes(`href="http://127.0.0.1:${frontendPort}/ru/articles/missing-article"`),
    ],
    [
      'missing detail preflight',
      hasRequest(pageRequests, '/api/articles/detail/missing-article', 'language=ru'),
    ],
    ['no analytics request', pageRequests.every((entry) => !entry.includes('/analytics/'))],
    ['no reaction request', pageRequests.every((entry) => !entry.includes('/reaction'))],
  ];
  assertExpected(expected, html, 'missing article SSR');
}

async function assertMissingMatrixQuestionNoindex(frontendPort, requests) {
  const requestStart = requests.length;
  const response = await fetch(
    `http://127.0.0.1:${frontendPort}/ru/competency-matrix/questions/missing-question`,
  );
  const html = await response.text();
  const pageRequests = requests.slice(requestStart);
  const expected = [
    ['status 404', response.status === 404],
    ['noindex', html.includes('<meta name="robots" content="noindex, follow">')],
    [
      'canonical',
      html.includes(
        `href="http://127.0.0.1:${frontendPort}/ru/competency-matrix/questions/missing-question"`,
      ),
    ],
    [
      'missing matrix preflight',
      hasRequest(pageRequests, '/api/competency-matrix/items/public/missing-question', 'language=ru'),
    ],
    ['no analytics request', pageRequests.every((entry) => !entry.includes('/analytics/'))],
    ['no reaction request', pageRequests.every((entry) => !entry.includes('/reaction'))],
  ];
  assertExpected(expected, html, 'missing matrix question SSR');
}

function hasRequest(requests, pathname, searchPart) {
  return requests.some((entry) => entry.includes(pathname) && entry.includes(searchPart));
}

function assertExpected(expected, html, label) {
  const failures = expected.filter(([, ok]) => !ok).map(([name]) => name);
  if (failures.length > 0) {
    console.error(html.slice(0, 4000));
    throw new Error(`SSR smoke failed for ${label}: ${failures.join(', ')}`);
  }
}
