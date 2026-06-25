# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Production-like public smoke", type: :request do
  before do
    LegalDocuments::Sync.call
  end

  SMOKE_INTERNAL_MARKERS = [
    "SECRET_KEY_BASE",
    "RAILS_MASTER_KEY",
    "DATABASE_URL",
    "RECIFY_DATABASE_PASSWORD",
    "Rails.root",
    "ActiveRecord::",
    "ActiveStorage::",
    "SolidQueue",
    "translation missing"
  ].freeze

  def html_document
    Nokogiri::HTML(response.body)
  end

  def xml_document
    Nokogiri::XML(response.body) { |config| config.strict }
  end

  def expect_no_internal_markers(body)
    SMOKE_INTERNAL_MARKERS.each do |marker|
      expect(body).not_to include(marker)
    end
  end

  def robots_disallow_paths
    get "/robots.txt"

    response.body.lines.filter_map do |line|
      line.match(/\ADisallow:\s*(\S+)/)&.[](1)
    end
  end

  def sitemap_paths
    get sitemap_path

    xml_document.xpath("//sm:loc", "sm" => "http://www.sitemaps.org/schemas/sitemap/0.9").map do |node|
      URI.parse(node.text).path
    end
  end

  def current_legal_version_path(document_type)
    document = LegalDocument.current!(document_type, locale: :ja)

    case document_type.to_s
    when "terms"
      terms_version_path(document.version)
    when "privacy"
      privacy_version_path(document.version)
    end
  end

  it "public HTML entrypoints are ready for production-like smoke" do
    announcement = create(:announcement, :published, title: "公開お知らせ", body: "公開本文")
    indexable_paths = [
      root_path,
      terms_path,
      privacy_path
    ]
    noindex_paths = [
      terms_versions_path,
      current_legal_version_path(:terms),
      privacy_versions_path,
      current_legal_version_path(:privacy),
      contact_path,
      announcements_path,
      announcement_path(announcement)
    ]

    indexable_paths.each do |path|
      get path

      aggregate_failures path do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/html")
        expect(html_document.at_css("main")).to be_present
        expect(html_document.at_css('meta[name="robots"]')&.[]("content")).to eq("index, follow")
        expect(html_document.at_css('meta[property="og:image"]')&.[]("content")).to match(%r{\Ahttps?://.+recify-ogp.+\.png\z})
        expect(html_document.at_css('meta[name="twitter:image"]')&.[]("content")).to eq(
          html_document.at_css('meta[property="og:image"]')&.[]("content")
        )
        expect(html_document.at_css('link[rel="canonical"]')&.[]("href")).to match(%r{\Ahttps?://})
        expect(response.body).not_to include('href="#"')
        expect_no_internal_markers(response.body)
      end
    end

    noindex_paths.each do |path|
      get path

      aggregate_failures path do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/html")
        expect(html_document.at_css("main")).to be_present
        expect(html_document.at_css('meta[name="robots"]')&.[]("content")).to eq("noindex, nofollow")
        expect(html_document.at_css('meta[property="og:image"]')).to be_nil
        expect(html_document.at_css('meta[name="twitter:image"]')).to be_nil
        expect(html_document.at_css('link[rel="canonical"]')).to be_nil
        expect(response.body).not_to include('href="#"')
        expect_no_internal_markers(response.body)
      end
    end
  end

  it "legal document YAML and database state are synchronized" do
    expect(LegalDocuments::Verifier.verify_database!).to be(true)
  end

  it "machine-readable and static smoke endpoints stay small and safe" do
    [
      [ rails_health_check_path, "text/html" ],
      [ "/robots.txt", "text/plain" ],
      [ sitemap_path, "application/xml" ],
      [ "/404.html", "text/html" ],
      [ "/500.html", "text/html" ]
    ].each do |path, media_type|
      get path

      aggregate_failures path do
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq(media_type)
        expect(response.body.bytesize).to be <= 20.kilobytes
        expect_no_internal_markers(response.body)
      end
    end
  end

  it "sitemap index URLs are not contradicted by robots exclusions" do
    create(:announcement, :published, title: "公開お知らせ")
    create(:announcement, title: "下書き")

    disallow_paths = robots_disallow_paths
    sitemap_paths.each do |path|
      aggregate_failures path do
        expect(disallow_paths.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }).to be(false)
      end
    end

    aggregate_failures "legal version URLs are intentionally omitted from sitemap" do
      expect(sitemap_paths).to contain_exactly(root_path, terms_path, privacy_path)
      expect(sitemap_paths).not_to include(contact_path)
      expect(sitemap_paths).not_to include(announcements_path)
      expect(sitemap_paths).not_to include(terms_versions_path)
      expect(sitemap_paths).not_to include(current_legal_version_path(:terms))
      expect(sitemap_paths).not_to include(privacy_versions_path)
      expect(sitemap_paths).not_to include(current_legal_version_path(:privacy))
    end
  end
end
