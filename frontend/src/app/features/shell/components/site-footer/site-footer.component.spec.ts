import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { provideI18nTesting } from '../../../../testing/i18n-testing';
import { SiteFooterComponent } from './site-footer.component';

describe('SiteFooterComponent', () => {
  let fixture: ComponentFixture<SiteFooterComponent>;
  let el: HTMLElement;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [SiteFooterComponent],
      providers: [
        provideRouter([]),
        provideI18nTesting({
          'shell.footer.sourceCode': 'Исходный код',
          'shell.footer.siteBuild': 'Как устроен сайт',
          'shell.footer.updates': 'Обновления',
          'shell.footer.email': 'Эл. почта',
          'shell.footer.githubProfile': 'Профиль GitHub',
          'shell.footer.telegramProfile': 'Профиль Telegram',
          'shell.footer.linkedinProfile': 'Профиль LinkedIn',
        }),
      ],
    }).compileComponents();

    fixture = TestBed.createComponent(SiteFooterComponent);
    fixture.detectChanges();
    el = fixture.nativeElement as HTMLElement;
  });

  it('renders link to /api/docs', () => {
    const link = el.querySelector('a[href="/api/docs"]');
    expect(link).not.toBeNull();
  });

  it('renders routerLink to /sitemap', () => {
    const link = el.querySelector('a[routerLink="/sitemap"]');
    expect(link).not.toBeNull();
  });

  it('renders localized link to the site-build case study', () => {
    const link = el.querySelector('a[href="/ru/how-this-site-is-built"]');

    expect(link).not.toBeNull();
    expect(link?.textContent?.trim()).toBe('Как устроен сайт');
  });

  it('renders localized link to updates', () => {
    const link = el.querySelector('a[href="/ru/updates"]');

    expect(link).not.toBeNull();
    expect(link?.textContent?.trim()).toBe('Обновления');
  });

  it('uses wrapping footer link groups for narrow screens', () => {
    const footerLayout = el.querySelector(
      '[data-testid="site-footer-layout"]',
    ) as HTMLElement | null;
    const textLinks = el.querySelector('[data-testid="site-footer-links"]') as HTMLElement | null;
    const socialLinks = el.querySelector(
      '[data-testid="site-footer-social"]',
    ) as HTMLElement | null;

    expect(footerLayout).not.toBeNull();
    expect(footerLayout?.classList).toContain('flex-column');
    expect(footerLayout?.classList).toContain('flex-md-row');
    expect(textLinks).not.toBeNull();
    expect(textLinks?.classList).toContain('flex-wrap');
    expect(socialLinks).not.toBeNull();
    expect(socialLinks?.classList).toContain('justify-content-md-end');
  });

  it('renders GitHub profile link', () => {
    const link = el.querySelector('a[href="https://github.com/ALittleMoron"]');
    expect(link).not.toBeNull();
  });

  it('renders source code link to the GitHub organization', () => {
    const link = el.querySelector('a[href="https://github.com/alittlemore-dev"]');
    expect(link).not.toBeNull();
    expect(link?.textContent?.trim()).toBe('Исходный код');
  });

  it('renders localized source and social labels', () => {
    expect(el.textContent).toContain('Исходный код');
    expect(el.querySelector('a[aria-label="Профиль GitHub"]')).not.toBeNull();
    expect(el.querySelector('a[aria-label="Эл. почта"]')).not.toBeNull();
    expect(el.querySelector('a[aria-label="Профиль Telegram"]')).not.toBeNull();
    expect(el.querySelector('a[aria-label="Профиль LinkedIn"]')).not.toBeNull();
  });

  it('renders email link', () => {
    const link = el.querySelector('a[href="mailto:d.lunev.dev@gmail.com"]');
    expect(link).not.toBeNull();
  });

  it('renders Telegram link', () => {
    const link = el.querySelector('a[href="https://t.me/alm_dmitriy_dev"]');
    expect(link).not.toBeNull();
  });

  it('renders LinkedIn link', () => {
    const link = el.querySelector('a[href="https://www.linkedin.com/in/dmitriy-lunev/"]');
    expect(link).not.toBeNull();
  });
});
