# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Sitemap", type: :request do
  around do |example|
    original_routes_options = Rails.application.routes.default_url_options.dup
    original_mailer_options = Rails.application.config.action_mailer.default_url_options.dup

    Rails.application.routes.default_url_options.clear
    Rails.application.config.action_mailer.default_url_options = { host: "example.com" }

    example.run
  ensure
    Rails.application.routes.default_url_options.clear
    Rails.application.routes.default_url_options.merge!(original_routes_options)
    Rails.application.config.action_mailer.default_url_options = original_mailer_options
  end

  def sitemap_locs
    document = Nokogiri::XML(response.body)
    document.xpath("//sm:loc", "sm" => "http://www.sitemaps.org/schemas/sitemap/0.9").map(&:text)
  end

  describe "GET /sitemap.xml" do
    it "公開ページと公開中のお知らせだけをXMLで返す" do
      visible = create(:announcement, :published, title: "公開お知らせ")
      draft = create(:announcement, title: "下書き")
      archived = create(:announcement, :archived, title: "アーカイブ")
      scheduled = create(:announcement, :scheduled, title: "予約")
      expired = create(:announcement, :expired, title: "終了")

      get sitemap_path

      locs = sitemap_locs

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/xml")
        expect(locs).to include(
          "http://example.com/",
          "http://example.com/terms",
          "http://example.com/privacy",
          "http://example.com/contact",
          "http://example.com/announcements",
          "http://example.com#{announcement_path(visible)}"
        )
        expect(locs).not_to include("http://example.com#{announcement_path(draft)}")
        expect(locs).not_to include("http://example.com#{announcement_path(archived)}")
        expect(locs).not_to include("http://example.com#{announcement_path(scheduled)}")
        expect(locs).not_to include("http://example.com#{announcement_path(expired)}")
        expect(locs).not_to include("http://example.com#{terms_versions_path}")
        expect(locs).not_to include("http://example.com#{terms_version_path('2026-06-21')}")
        expect(locs).not_to include("http://example.com#{privacy_versions_path}")
        expect(locs).not_to include("http://example.com#{privacy_version_path('2026-06-21')}")
        expect(response.body).not_to include("/admin")
        expect(response.body).not_to include("/receipts")
        expect(response.body).not_to include("/settings")
        expect(response.body).not_to include("/notifications")
        expect(response.body).not_to include("/users")
        expect(response.body).not_to include("/rails/active_storage")
      end
    end

    it "設定済みhostを優先し、Host headerをsitemap URLへ反映しない" do
      Rails.application.routes.default_url_options.clear
      Rails.application.routes.default_url_options.merge!(host: "recify-app.test", protocol: "https")

      get sitemap_path, headers: { "HOST" => "evil.example" }

      aggregate_failures do
        expect(sitemap_locs).to include("https://recify-app.test/")
        expect(response.body).not_to include("evil.example")
      end
    end
  end
end
