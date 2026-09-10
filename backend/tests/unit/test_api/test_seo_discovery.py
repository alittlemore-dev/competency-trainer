from datetime import UTC, datetime

import pytest_asyncio
from httpx import codes

from core.articles.schemas import PublishedArticleForSeo, PublishedArticlesForSeo
from core.competency_matrix.schemas import (
    PublishedCompetencyMatrixItemForSeo,
    PublishedCompetencyMatrixItemsForSeo,
)
from core.enums import PublishStatusEnum
from tests.test_cases import ApiTestCase


class TestSeoDiscoveryAPI(ApiTestCase):
    @pytest_asyncio.fixture(autouse=True)
    async def setup(self) -> None:
        self.articles_use_case = await self.container.get_articles_use_case()
        self.matrix_use_case = await self.container.get_competency_matrix_use_case()

    def test_sitemap_contains_language_prefixed_public_pages_and_published_articles(self) -> None:
        article = PublishedArticleForSeo(
            slug="typed-articles",
            publish_status=PublishStatusEnum.PUBLISHED,
            updated_at=datetime(2026, 2, 4, 4, 5, 6, tzinfo=UTC),
        )
        self.articles_use_case.list_published_articles_for_seo.return_value = (
            PublishedArticlesForSeo(
                values=[article],
            )
        )
        self.matrix_use_case.list_published_items_for_seo.return_value = (
            PublishedCompetencyMatrixItemsForSeo(
                values=[
                    PublishedCompetencyMatrixItemForSeo(
                        slug="how-to-write-function",
                        publish_status=PublishStatusEnum.PUBLISHED,
                    ),
                ],
            )
        )

        response = self.no_auth_api.get_sitemap_xml()

        assert response.status_code == codes.OK, response.content
        assert response.headers["content-type"].startswith("application/xml")
        sitemap = response.text
        assert "http://localhost:8000/ru/about-me" not in sitemap
        assert "http://localhost:8000/en/about-me" not in sitemap
        assert "<loc>http://localhost:8000/ru/how-this-site-is-built</loc>" in sitemap
        assert "<loc>http://localhost:8000/en/how-this-site-is-built</loc>" in sitemap
        assert "<loc>http://localhost:8000/ru/updates</loc>" in sitemap
        assert "<loc>http://localhost:8000/en/updates</loc>" in sitemap
        assert "<loc>http://localhost:8000/ru/competency/articles/typed-articles</loc>" in sitemap
        assert "<loc>http://localhost:8000/en/competency/articles/typed-articles</loc>" in sitemap
        assert (
            "<loc>http://localhost:8000/ru/competency/matrix/questions/how-to-write-function</loc>"
            in sitemap
        )
        assert (
            "<loc>http://localhost:8000/en/competency/matrix/questions/how-to-write-function</loc>"
            in sitemap
        )
        assert (
            'hreflang="ru" href="http://localhost:8000/ru/competency/articles/typed-articles"'
            in sitemap
        )
        assert (
            'hreflang="en" href="http://localhost:8000/en/competency/articles/typed-articles"'
            in sitemap
        )
        assert (
            'hreflang="ru" '
            'href="http://localhost:8000/ru/competency/matrix/questions/how-to-write-function"'
            in sitemap
        )
        assert (
            'hreflang="en" '
            'href="http://localhost:8000/en/competency/matrix/questions/how-to-write-function"'
            in sitemap
        )
        assert "<lastmod>2026-02-04T04:05:06+00:00</lastmod>" in sitemap
        self.articles_use_case.list_published_articles_for_seo.assert_called_once_with()
        self.matrix_use_case.list_published_items_for_seo.assert_called_once_with()

    def test_sitemap_skips_draft_articles_and_matrix_items_returned_defensively(self) -> None:
        draft = PublishedArticleForSeo(
            slug="draft-article",
            publish_status=PublishStatusEnum.DRAFT,
            updated_at=datetime(2026, 2, 4, 4, 5, 6, tzinfo=UTC),
        )
        self.articles_use_case.list_published_articles_for_seo.return_value = (
            PublishedArticlesForSeo(
                values=[draft],
            )
        )
        self.matrix_use_case.list_published_items_for_seo.return_value = (
            PublishedCompetencyMatrixItemsForSeo(
                values=[
                    PublishedCompetencyMatrixItemForSeo(
                        slug="draft-question",
                        publish_status=PublishStatusEnum.DRAFT,
                    ),
                ],
            )
        )

        response = self.no_auth_api.get_sitemap_xml()

        assert response.status_code == codes.OK, response.content
        assert "/articles/draft-article" not in response.text
        assert "/competency-matrix/questions/draft-question" not in response.text

    def test_robots_allows_public_language_routes_and_blocks_duplicate_spa_routes(self) -> None:
        response = self.no_auth_api.get_robots_txt()

        assert response.status_code == codes.OK, response.content
        assert response.headers["content-type"].startswith("text/plain")
        assert response.text == (
            "User-agent: *\n"
            "Allow: /ru/\n"
            "Allow: /en/\n"
            "Allow: /sitemap.xml\n"
            "Disallow: /api/\n"
            "Disallow: /login\n"
            "Disallow: /how-this-site-is-built\n"
            "Disallow: /updates\n"
            "Disallow: /articles\n"
            "Disallow: /competency-matrix\n"
            "Disallow: /competency\n"
            "Disallow: /sitemap\n"
            "Sitemap: http://localhost:8000/sitemap.xml\n"
        )
