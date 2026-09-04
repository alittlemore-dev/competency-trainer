import http from 'node:http';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { gzipSync } from 'node:zlib';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const frontendRoot = resolve(scriptDir, '..');
const defaultServerEntry = pathToFileURL(
  resolve(frontendRoot, 'dist/competency-trainer-frontend/server/server.mjs'),
).href;
const ARTICLE_COVER_PATH = '/api/fixtures/article-cover.svg';
const ARTICLE_COVER_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900" viewBox="0 0 1600 900">'
  + '<rect width="1600" height="900" fill="#198754"/>'
  + '<path d="M0 720 400 360l320 288 240-216 640 468H0Z" fill="#f8f9fa"/>'
  + '</svg>';

export const articleDto = {
  id: '00000000-0000-0000-0000-000000000001',
  title: 'Typed articles',
  slug: 'typed-articles',
  folder: 'Engineering',
  authorUsername: 'admin',
  publishedAt: '2026-01-02T03:04:05+00:00',
  publishStatus: 'Published',
  updatedAt: '2026-01-03T03:04:05+00:00',
  excerpt: 'Fallback excerpt',
  metadata: {
    seoTitleRu: 'SEO Typed articles RU',
    seoTitleEn: 'SEO Typed articles EN',
    seoDescriptionRu:
      'SEO description RU with enough text to be useful for search snippets and social cards.',
    seoDescriptionEn:
      'SEO description EN with enough text to be useful for search snippets and social cards.',
    coverImageUrl: ARTICLE_COVER_PATH,
    coverImageAltRu: 'Typed articles cover RU',
    coverImageAltEn: 'Typed articles cover',
  },
  tags: [
    {
      id: 1,
      name: 'Angular',
      slug: 'angular',
      translations: {
        ru: { name: 'Angular' },
        en: { name: 'Angular' },
      },
    },
  ],
  content:
    '## Rendered SSR article body\n\nRead [[matrix:how-to-write-function|matrix question]].\n\n```ts\nconst answer = 42;\n```',
  createdAt: '2026-01-01T03:04:05+00:00',
  translations: {
    ru: {
      title: 'Typed articles',
      content:
        '## Rendered SSR article body\n\nRead [[matrix:how-to-write-function|matrix question]].\n\n```ts\nconst answer = 42;\n```',
      folder: 'Engineering',
    },
    en: {
      title: 'Typed articles EN',
      content: '## Rendered SSR article body EN',
      folder: 'Engineering',
    },
  },
};

export const matrixQuestionDto = {
  id: 1,
  slug: 'how-to-write-function',
  question: 'Как написать функцию?',
  answer:
    '## Rendered SSR matrix answer\n\nФункция должна быть маленькой и проверяемой. См. [[articles:typed-articles|typed article]].\n\n```python\ndef answer():\n    return 42\n```',
  interviewAnswerExplanation: 'Покажите сигнатуру, ветвление и тест.',
  sheetKey: 'python',
  sheet: 'Python',
  grade: 'Junior',
  section: 'Основы',
  subsection: 'Функции',
  publishStatus: 'Published',
  translations: {
    ru: {
      question: 'Как написать функцию?',
      answer:
        '## Rendered SSR matrix answer\n\nФункция должна быть маленькой и проверяемой. См. [[articles:typed-articles|typed article]].\n\n```python\ndef answer():\n    return 42\n```',
      interviewAnswerExplanation: 'Покажите сигнатуру, ветвление и тест.',
      sheet: 'Python',
      section: 'Основы',
      subsection: 'Функции',
    },
    en: {
      question: 'How to write a function?',
      answer: '## Rendered SSR matrix answer\n\nA function should be small and testable.',
      interviewAnswerExplanation: 'Show a signature, a branch, and a test.',
      sheet: 'Python',
      section: 'Basics',
      subsection: 'Functions',
    },
  },
  resources: [],
};

export async function startSsrFixture(options = {}) {
  const frontendPortOption = options.frontendPort ?? 0;
  const requests = [];
  const backendHandler = createMockBackendHandler(requests);
  const backend = http.createServer(backendHandler);

  await listen(backend, options.backendPort ?? 0);
  const backendPort = backend.address().port;
  process.env.SSR_API_ORIGIN = `http://127.0.0.1:${backendPort}`;
  process.env.APP_URL_SCHEMA = 'http';
  process.env.APP_DOMAIN = '127.0.0.1';
  process.env.NG_ALLOWED_HOSTS = '127.0.0.1';

  const serverHandler = import(options.serverEntry ?? defaultServerEntry);
  const frontend = createFrontendServer(serverHandler, backendHandler);
  await listen(frontend, frontendPortOption);
  const frontendPort = frontend.address().port;
  process.env.SSR_PUBLIC_ORIGIN = `http://127.0.0.1:${frontendPort}`;

  return {
    backend,
    frontend,
    backendPort,
    frontendPort,
    requests,
    async close() {
      await Promise.all([closeServer(frontend), closeServer(backend)]);
    },
  };
}

function createFrontendServer(serverHandler, backendHandler) {
  return http.createServer(async (req, res) => {
    installGzipForTextResponses(req, res);

    try {
      const url = new URL(req.url ?? '/', 'http://frontend.local');
      if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/robots.txt') {
        writeText(res, 'text/plain; charset=utf-8', buildRobotsTxt(readFixtureOrigin(req)));
        return;
      }

      if ((req.method === 'GET' || req.method === 'HEAD') && url.pathname === '/sitemap.xml') {
        writeText(res, 'application/xml; charset=utf-8', buildSitemapXml(readFixtureOrigin(req)));
        return;
      }

      if (url.pathname.startsWith('/api/')) {
        backendHandler(req, res);
        return;
      }

      const { reqHandler } = await serverHandler;
      reqHandler(req, res, (error) => {
        res.statusCode = error ? 500 : 404;
        res.end(error ? String(error) : 'Not found');
      });
    } catch (error) {
      res.statusCode = 500;
      res.end(String(error));
    }
  });
}

function installGzipForTextResponses(req, res) {
  const originalWriteHead = res.writeHead.bind(res);
  const originalEnd = res.end.bind(res);
  const chunks = [];

  res.writeHead = (...args) => {
    applyWriteHeadArgs(res, args);
    return res;
  };

  res.write = (chunk, encoding, callback) => {
    const normalized = normalizeWriteArgs(chunk, encoding, callback);
    if (normalized.chunk !== undefined) {
      chunks.push(toBuffer(normalized.chunk, normalized.encoding));
    }
    normalized.callback?.();
    return true;
  };

  res.end = (chunk, encoding, callback) => {
    const normalized = normalizeWriteArgs(chunk, encoding, callback);
    if (normalized.chunk !== undefined) {
      chunks.push(toBuffer(normalized.chunk, normalized.encoding));
    }

    const body = Buffer.concat(chunks);
    if (!shouldGzipResponse(req, res, body)) {
      res.writeHead = originalWriteHead;
      return originalEnd(body, normalized.callback);
    }

    const gzippedBody = gzipSync(body);
    res.setHeader('Content-Encoding', 'gzip');
    res.setHeader('Vary', appendVaryAcceptEncoding(res.getHeader('Vary')));
    res.setHeader('Content-Length', String(gzippedBody.length));
    res.writeHead = originalWriteHead;
    return originalEnd(gzippedBody, normalized.callback);
  };
}

function applyWriteHeadArgs(res, args) {
  const [statusCode, statusMessageOrHeaders, maybeHeaders] = args;
  if (Number.isInteger(statusCode)) {
    res.statusCode = statusCode;
  }

  const headers =
    typeof statusMessageOrHeaders === 'string' ? maybeHeaders : statusMessageOrHeaders;
  if (typeof statusMessageOrHeaders === 'string') {
    res.statusMessage = statusMessageOrHeaders;
  }
  if (headers === undefined) return;

  if (Array.isArray(headers)) {
    for (let index = 0; index < headers.length; index += 2) {
      res.setHeader(headers[index], headers[index + 1]);
    }
    return;
  }

  for (const [name, value] of Object.entries(headers)) {
    res.setHeader(name, value);
  }
}

function normalizeWriteArgs(chunk, encoding, callback) {
  if (typeof chunk === 'function') {
    return { chunk: undefined, encoding: undefined, callback: chunk };
  }
  if (typeof encoding === 'function') {
    return { chunk, encoding: undefined, callback: encoding };
  }
  return { chunk, encoding, callback };
}

function toBuffer(chunk, encoding) {
  if (Buffer.isBuffer(chunk)) return chunk;
  if (chunk instanceof Uint8Array) return Buffer.from(chunk);
  return Buffer.from(String(chunk), encoding);
}

function shouldGzipResponse(req, res, body) {
  const acceptEncoding = String(req.headers['accept-encoding'] ?? '');
  const contentType = String(res.getHeader('Content-Type') ?? '').toLowerCase();
  return (
    body.length > 0 &&
    acceptEncoding.includes('gzip') &&
    !res.hasHeader('Content-Encoding') &&
    res.statusCode !== 204 &&
    res.statusCode !== 304 &&
    isCompressibleContentType(contentType)
  );
}

function isCompressibleContentType(contentType) {
  return (
    contentType.startsWith('text/') ||
    contentType.includes('javascript') ||
    contentType.includes('json') ||
    contentType.includes('xml') ||
    contentType.includes('svg')
  );
}

function appendVaryAcceptEncoding(value) {
  if (value === undefined) return 'Accept-Encoding';
  const current = Array.isArray(value) ? value.join(', ') : String(value);
  return current
    .split(',')
    .map((part) => part.trim().toLowerCase())
    .includes('accept-encoding')
    ? current
    : `${current}, Accept-Encoding`;
}

function readFixtureOrigin(req) {
  const explicitOrigin = process.env.SSR_PUBLIC_ORIGIN?.trim();
  if (explicitOrigin) return explicitOrigin;

  const host = req.headers.host ?? '127.0.0.1';
  return `http://${host}`;
}

function buildRobotsTxt(origin) {
  return (
    'User-agent: *\n'
    + 'Allow: /ru/\n'
    + 'Allow: /en/\n'
    + 'Allow: /sitemap.xml\n'
    + 'Disallow: /api/\n'
    + 'Disallow: /login\n'
    + 'Disallow: /how-this-site-is-built\n'
    + 'Disallow: /updates\n'
    + 'Disallow: /articles\n'
    + 'Disallow: /competency-matrix\n'
    + 'Disallow: /sitemap\n'
    + `Sitemap: ${origin}/sitemap.xml\n`
  );
}

function buildSitemapXml(origin) {
  const urls = [
    '/ru/how-this-site-is-built',
    '/en/how-this-site-is-built',
    '/ru/updates',
    '/en/updates',
    '/ru/articles/typed-articles',
    '/en/articles/typed-articles',
    '/ru/competency-matrix/questions/how-to-write-function',
    '/en/competency-matrix/questions/how-to-write-function',
  ];
  const entries = urls
    .map((path) => `  <url>\n    <loc>${origin}${path}</loc>\n  </url>`)
    .join('\n');
  return (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
    + `${entries}\n`
    + '</urlset>\n'
  );
}

function writeText(res, contentType, body) {
  res.statusCode = 200;
  res.setHeader('Content-Type', contentType);
  res.end(body);
}

function createMockBackendHandler(requests) {
  return (req, res) => {
    const url = new URL(req.url ?? '/', 'http://backend.local');
    requests.push(`${req.method ?? 'GET'} ${url.pathname}${url.search}`);

    if (
      (req.method === 'GET' || req.method === 'HEAD')
      && url.pathname === ARTICLE_COVER_PATH
    ) {
      res.statusCode = 200;
      res.setHeader('Content-Type', 'image/svg+xml; charset=utf-8');
      res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
      res.end(req.method === 'HEAD' ? undefined : ARTICLE_COVER_SVG);
      return;
    }

    res.setHeader('Content-Type', 'application/json');

    if (url.pathname === '/api/i18n/languages') {
      writeJson(res, {
        defaultLanguage: 'ru',
        languages: [
          { code: 'ru', label: 'Russian' },
          { code: 'en', label: 'English' },
        ],
      });
      return;
    }

    if (url.pathname === '/api/i18n/bundles/ru' || url.pathname === '/api/i18n/bundles/en') {
      writeJson(res, {
        language: url.pathname.endsWith('/en') ? 'en' : 'ru',
        messages: buildMessages(),
      });
      return;
    }

    if (url.pathname === '/api/articles') {
      writeJson(res, {
        totalCount: 1,
        totalPages: 1,
        articles: [articleSummary(req)],
      });
      return;
    }

    if (url.pathname === '/api/articles/detail/typed-articles') {
      writeJson(res, articleDtoForRequest(req));
      return;
    }

    if (url.pathname === '/api/articles/detail/typed-articles/analytics/view') {
      writeNoContent(res);
      return;
    }

    if (url.pathname === '/api/articles/detail/typed-articles/analytics/engaged-view') {
      writeNoContent(res);
      return;
    }

    if (url.pathname === '/api/articles/detail/typed-articles/reaction') {
      writeNoContent(res);
      return;
    }

    if (url.pathname === '/api/articles/public-stats') {
      writeJson(res, {
        stats: [
          {
            articleId: articleDto.id,
            viewCount: 7,
            reactionCounts: {
              heart: 1,
              fire: 0,
              thinking: 0,
              neutral: 0,
              poop: 0,
            },
          },
        ],
      });
      return;
    }

    if (url.pathname === '/api/articles/tags') {
      writeJson(res, { tags: articleDto.tags });
      return;
    }

    if (url.pathname === '/api/articles/tree') {
      writeJson(res, {
        folders: [
          {
            folder: 'Engineering',
            articles: [
              {
                title: 'Typed articles',
                slug: 'typed-articles',
                publishStatus: 'Published',
                publishedAt: articleDto.publishedAt,
                updatedAt: articleDto.updatedAt,
              },
            ],
          },
        ],
      });
      return;
    }

    if (url.pathname === '/api/competency-matrix/sheets') {
      writeJson(res, {
        sheets: [{ key: matrixQuestionDto.sheetKey, name: matrixQuestionDto.sheet }],
      });
      return;
    }

    if (url.pathname === '/api/competency-matrix/items') {
      writeJson(res, {
        sheetKey: matrixQuestionDto.sheetKey,
        sheet: matrixQuestionDto.sheet,
        sections: [
          {
            section: matrixQuestionDto.section,
            subsections: [
              {
                subsection: matrixQuestionDto.subsection,
                grades: [
                  {
                    grade: matrixQuestionDto.grade,
                    items: [
                      {
                        id: matrixQuestionDto.id,
                        slug: matrixQuestionDto.slug,
                        question: matrixQuestionDto.question,
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      });
      return;
    }

    if (url.pathname === '/api/competency-matrix/items/public/how-to-write-function') {
      writeJson(res, matrixQuestionDto);
      return;
    }

    res.statusCode = 404;
    writeJson(res, { code: 'not_found', type: 'not_found', message: url.pathname });
  };
}

function articleDtoForRequest(req) {
  return {
    ...articleDto,
    metadata: {
      ...articleDto.metadata,
      coverImageUrl: `${readFixtureOrigin(req)}${ARTICLE_COVER_PATH}`,
    },
  };
}

function articleSummary(req) {
  const responseArticle = articleDtoForRequest(req);
  return {
    id: responseArticle.id,
    title: responseArticle.title,
    slug: responseArticle.slug,
    folder: responseArticle.folder,
    authorUsername: responseArticle.authorUsername,
    publishedAt: responseArticle.publishedAt,
    publishStatus: responseArticle.publishStatus,
    updatedAt: responseArticle.updatedAt,
    excerpt: responseArticle.excerpt,
    metadata: responseArticle.metadata,
    tags: responseArticle.tags,
  };
}

function buildMessages() {
  return {
    'app.siteName': 'Competency Trainer',
    'shell.nav.matrix': 'Matrix',
    'shell.nav.articles': 'Articles',
    'shell.nav.toggleNavigation': 'Toggle navigation',
    'shell.theme.dark': 'Dark',
    'shell.theme.light': 'Light',
    'shell.theme.toggle': 'Theme',
    'shell.language.label': 'Language',
    'shell.auth.login': 'Login',
    'shell.footer.sourceCode': 'Source code',
    'shell.footer.siteBuild': 'How this site is built',
    'shell.footer.updates': 'Updates',
    'shell.footer.email': 'Email',
    'shell.footer.githubProfile': 'GitHub',
    'shell.footer.telegramProfile': 'Telegram',
    'shell.footer.linkedinProfile': 'LinkedIn',
    'siteBuild.seo.title': 'How this site is built',
    'siteBuild.seo.description': 'An engineering case study about this portfolio and articles site.',
    'siteBuild.hero.kicker': 'Case study',
    'siteBuild.hero.title': 'How this site is built',
    'siteBuild.hero.lead': 'Engineering case study of a production-minded portfolio and articles site.',
    'siteBuild.hero.sourceCode': 'Source code',
    'siteBuild.hero.matrixLink': 'Open matrix',
    'siteBuild.hero.logoAlt': 'Site logo',
    'siteBuild.problem.title': 'Problem',
    'siteBuild.problem.body': 'Articles, competency matrix, and architecture notes in one product.',
    'siteBuild.architecture.title': 'Architecture',
    'siteBuild.architecture.backendTitle': 'Backend',
    'siteBuild.architecture.backendBody': 'Litestar, SQLAlchemy, Dishka, and PostgreSQL.',
    'siteBuild.architecture.frontendTitle': 'Frontend',
    'siteBuild.architecture.frontendBody': 'Angular hybrid SSR/CSR and backend-driven i18n.',
    'siteBuild.architecture.infraTitle': 'Infrastructure',
    'siteBuild.architecture.infraBody': 'nginx, Docker, MinIO, Valkey, and TaskIQ.',
    'siteBuild.decisions.title': 'Engineering decisions',
    'siteBuild.decision.cleanArchitecture': 'Clean Architecture',
    'siteBuild.decision.localizedContent': 'RU/EN localization',
    'siteBuild.decision.privacyAnalytics': 'Privacy-safe analytics',
    'siteBuild.quality.title': 'Quality and operations',
    'siteBuild.quality.body':
      'Layered quality checks cover fast feedback, production readiness, and rollout risk.',
    'siteBuild.next.title': 'Next',
    'siteBuild.next.body': 'Feeds, public roadmap, and deployment hardening.',
    'siteBuild.next.articlesLink': 'Go to articles',
    'updates.seo.title': 'Updates',
    'updates.seo.description': 'Public changelog for the portfolio and articles site.',
    'updates.hero.kicker': 'Changelog',
    'updates.hero.title': 'Updates',
    'updates.hero.lead':
      'Major changes to the portfolio and articles site, grouped by month: public content, admin workflows, quality, security, and infrastructure.',
    'updates.tag.frontend': 'Frontend',
    'updates.tag.backend': 'Backend',
    'updates.tag.content': 'Content',
    'updates.tag.seo': 'SEO',
    'updates.tag.analytics': 'Analytics',
    'updates.tag.matrix': 'Matrix',
    'updates.tag.infra': 'Infrastructure',
    'updates.tag.admin': 'Admin',
    'updates.tag.auth': 'Auth',
    'updates.tag.localization': 'Localization',
    'updates.tag.quality': 'Quality',
    'updates.tag.security': 'Security',
    'updates.tag.delivery': 'Delivery',
    'articles.title': 'Articles',
    'articles.views': '{count} views',
    'articles.filters.search': 'Search',
    'articles.filters.searchPlaceholder': 'Search articles',
    'articles.filters.from': 'From',
    'articles.filters.to': 'To',
    'articles.filters.apply': 'Apply',
    'articles.filters.reset': 'Reset',
    'articles.sidePanel.open': 'Open articles tree',
    'articles.sidePanel.close': 'Close articles tree',
    'articles.datePicker.placeholder': 'yyyy-mm-dd',
    'articles.datePicker.open': 'Open calendar',
    'articles.datePicker.previousMonth': 'Previous month',
    'articles.datePicker.nextMonth': 'Next month',
    'articles.datePicker.openMonthYearPicker': 'Choose month and year',
    'articles.datePicker.previousYear': 'Previous year',
    'articles.datePicker.nextYear': 'Next year',
    'articles.reactions': 'Reactions',
    'matrix.title': 'Competency matrix',
    'matrix.seo.title': 'Competency matrix',
    'matrix.seo.description': 'Competency matrix for Junior/Middle/Senior developers.',
    'matrix.grid.sheetsAria': 'Matrix sheets',
    'matrix.grid.section': 'Section',
    'matrix.grid.subsection': 'Subsection',
    'matrix.detail.question': 'Question:',
    'matrix.detail.answer': 'Answer:',
    'matrix.detail.interviewAnswerExplanation': 'Interview answer explanation:',
    'matrix.detail.resources': 'External resources:',
    'matrix.detailAria': 'Matrix question detail',
    'matrix.empty': 'No matrix questions found.',
    'shared.back': 'Back',
    'shared.close': 'Close',
    'shared.edit': 'Edit',
    'shared.loading': 'Loading',
    'shared.retry': 'Retry',
    'shared.notSet': 'Not set',
    'enum.grade.Junior': 'Junior',
    'enum.grade.JuniorPlus': 'Junior+',
    'enum.grade.Middle': 'Middle',
    'enum.grade.MiddlePlus': 'Middle+',
    'enum.grade.Senior': 'Senior',
    'enum.articleReaction.heart': 'Heart',
    'enum.articleReaction.fire': 'Fire',
    'enum.articleReaction.thinking': 'Thinking',
    'enum.articleReaction.neutral': 'Neutral',
    'enum.articleReaction.poop': 'Poop',
  };
}

function writeJson(res, body) {
  res.end(JSON.stringify(body));
}

function writeNoContent(res) {
  res.statusCode = 204;
  res.removeHeader('Content-Type');
  res.end();
}

function listen(server, port) {
  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', resolve);
  });
}

function closeServer(server) {
  return new Promise((resolve) => {
    server.close(resolve);
  });
}
