import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { SeoService } from '../../../../core/seo/seo.service';
import { provideI18nTesting } from '../../../../testing/i18n-testing';
import { SiteCaseStudyPageComponent } from './site-case-study-page.component';

describe('SiteCaseStudyPageComponent', () => {
  let fixture: ComponentFixture<SiteCaseStudyPageComponent>;
  let seoService: { setTranslatedMeta: jest.Mock };

  beforeEach(async () => {
    seoService = {
      setTranslatedMeta: jest.fn(),
    };

    await TestBed.configureTestingModule({
      imports: [SiteCaseStudyPageComponent],
      providers: [
        provideRouter([]),
        provideI18nTesting({
          'siteBuild.hero.title': 'Как устроен этот сайт',
          'siteBuild.hero.lead': 'Инженерный разбор production-подхода.',
          'siteBuild.hero.sourceCode': 'Исходный код',
          'siteBuild.problem.title': 'Задача',
          'siteBuild.problem.body':
            'Сайт объединяет статьи, матрицу компетенций и разбор собственной архитектуры.',
          'siteBuild.architecture.title': 'Архитектура',
          'siteBuild.architecture.backendTitle': 'Backend',
          'siteBuild.architecture.backendBody': 'Litestar, SQLAlchemy, Dishka и PostgreSQL.',
          'siteBuild.architecture.frontendTitle': 'Frontend',
          'siteBuild.architecture.frontendBody': 'Angular hybrid SSR/CSR и backend-driven i18n.',
          'siteBuild.architecture.infraTitle': 'Infrastructure',
          'siteBuild.architecture.infraBody': 'nginx, Docker, MinIO, Valkey и TaskIQ.',
          'siteBuild.architecture.agentTitle': 'Безопасный AI-доступ',
          'siteBuild.architecture.agentBody': 'Защищённый контур для AI-черновиков.',
          'siteBuild.decisions.title': 'Инженерные решения',
          'siteBuild.decision.cleanArchitecture': 'Clean Architecture',
          'siteBuild.decision.localizedContent': 'RU/EN локализация',
          'siteBuild.decision.privacyAnalytics': 'Privacy-safe аналитика',
          'siteBuild.decision.deployManifest': 'Manifest-driven deploy env',
          'siteBuild.quality.title': 'Качество и эксплуатация',
          'siteBuild.quality.body': 'Проверки качества, security gates и SSR smoke.',
          'siteBuild.next.title': 'Что дальше',
          'siteBuild.next.body': 'Performance, feeds, roadmap и deployment hardening.',
        }),
        { provide: SeoService, useValue: seoService },
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(SiteCaseStudyPageComponent);
    fixture.detectChanges();
  });

  it('sets localized SEO metadata for the canonical case-study page', () => {
    expect(seoService.setTranslatedMeta).toHaveBeenCalledWith({
      titleKey: 'siteBuild.seo.title',
      descriptionKey: 'siteBuild.seo.description',
      canonicalPath: '/ru/how-this-site-is-built',
      alternates: [
        { language: 'ru', path: '/ru/how-this-site-is-built' },
        { language: 'en', path: '/en/how-this-site-is-built' },
      ],
    });
  });

  it('renders the public case-study content and source-code CTA', () => {
    const pageText = fixture.nativeElement.textContent as string;
    const sourceLink = fixture.nativeElement.querySelector(
      'a[href="https://github.com/alittlemore-dev/competency-trainer"]',
    ) as HTMLAnchorElement | null;

    expect(pageText).toContain('Как устроен этот сайт');
    expect(pageText).toContain(
      'Сайт объединяет статьи, матрицу компетенций и разбор собственной архитектуры.',
    );
    expect(pageText).toContain('Litestar, SQLAlchemy, Dishka и PostgreSQL.');
    expect(pageText).toContain('Angular hybrid SSR/CSR и backend-driven i18n.');
    expect(pageText).toContain('Privacy-safe аналитика');
    expect(pageText).toContain('Manifest-driven deploy env');
    expect(sourceLink).not.toBeNull();
    expect(sourceLink?.getAttribute('rel')).toBe('noopener noreferrer');
  });

  it('serves the hero logo with responsive and LCP-friendly image hints', () => {
    const logo = fixture.nativeElement.querySelector(
      'img.site-case-study__logo',
    ) as HTMLImageElement | null;

    expect(logo).not.toBeNull();
    expect(logo?.getAttribute('src')).toBe('/logo-192x192.webp');
    expect(logo?.getAttribute('srcset')).toBe('/logo-192x192.webp 1x, /logo-512x512.webp 2x');
    expect(logo?.getAttribute('width')).toBe('168');
    expect(logo?.getAttribute('height')).toBe('168');
    expect(logo?.getAttribute('fetchpriority')).toBe('high');
    expect(logo?.getAttribute('loading')).toBe('eager');
    expect(logo?.getAttribute('decoding')).toBe('async');
  });
});
