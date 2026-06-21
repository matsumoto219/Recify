# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public meta tags", type: :request do
  before do
    LegalDocuments::Sync.call
  end

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

  def document
    Nokogiri::HTML(response.body)
  end

  def meta_name(name)
    document.at_css(%(meta[name="#{name}"]))&.[]("content")
  end

  def meta_property(property)
    document.at_css(%(meta[property="#{property}"]))&.[]("content")
  end

  def canonical_href
    document.at_css('link[rel="canonical"]')&.[]("href")
  end

  shared_examples "public OGP meta" do |expected_title:, expected_description:, expected_path:, expected_type: "website"|
    it "公開ページ用のOGP/Twitter/canonical metaを出す" do
      perform_request

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(document.at_css("title").text).to eq(expected_title)
        expect(meta_name("description")).to eq(expected_description)
        expect(canonical_href).to eq("http://example.com#{expected_path}")
        expect(meta_property("og:site_name")).to eq("Recify")
        expect(meta_property("og:title")).to eq(expected_title)
        expect(meta_property("og:description")).to eq(expected_description)
        expect(meta_property("og:type")).to eq(expected_type)
        expect(meta_property("og:url")).to eq("http://example.com#{expected_path}")
        expect(meta_property("og:image")).to match(%r{\Ahttp://example\.com/assets/.+recify-ogp.+\.png\z})
        expect(meta_name("twitter:card")).to eq("summary_large_image")
        expect(meta_name("twitter:title")).to eq(expected_title)
        expect(meta_name("twitter:description")).to eq(expected_description)
        expect(meta_name("twitter:image")).to eq(meta_property("og:image"))
        expect(response.body).not_to include("/admin")
        expect(response.body).not_to include("translation missing")
      end
    end
  end

  describe "GET /" do
    def perform_request
      get root_path
    end

    include_examples "public OGP meta",
                     expected_title: "Recify",
                     expected_description: I18n.t("home.meta.description"),
                     expected_path: "/"
  end

  describe "GET /announcements" do
    def perform_request
      get announcements_path
    end

    include_examples "public OGP meta",
                     expected_title: "お知らせ一覧 | Recify",
                     expected_description: I18n.t("announcements.index.meta_description"),
                     expected_path: "/announcements"
  end

  describe "GET /contact" do
    def perform_request
      get contact_path
    end

    include_examples "public OGP meta",
                     expected_title: "お問い合わせ | Recify",
                     expected_description: I18n.t("contact_requests.new.meta_description"),
                     expected_path: "/contact"
  end

  describe "GET /terms" do
    def perform_request
      get terms_path
    end

    include_examples "public OGP meta",
                     expected_title: "利用規約 | Recify",
                     expected_description: LegalDocuments::Repository.new.current!(document_type: :terms, locale: :ja).meta_description,
                     expected_path: "/terms"
  end

  describe "GET /privacy" do
    def perform_request
      get privacy_path
    end

    include_examples "public OGP meta",
                     expected_title: "プライバシーポリシー | Recify",
                     expected_description: LegalDocuments::Repository.new.current!(document_type: :privacy, locale: :ja).meta_description,
                     expected_path: "/privacy"
  end

  it "設定済みhostを優先し、Host headerをOGP URLへ反映しない" do
    Rails.application.routes.default_url_options.clear
    Rails.application.routes.default_url_options.merge!(host: "recify-app.test", protocol: "https")

    get root_path, headers: { "HOST" => "evil.example" }

    aggregate_failures do
      expect(canonical_href).to eq("https://recify-app.test/")
      expect(meta_property("og:url")).to eq("https://recify-app.test/")
      expect(meta_property("og:image")).to include("https://recify-app.test/")
      expect(response.body).not_to include("evil.example")
    end
  end

  it "お知らせ詳細のHTML風文字列をmeta属性内でescapeし、descriptionからタグ風部分を落とす" do
    announcement = create(
      :announcement,
      :published,
      title: '<script>alert("title")</script>',
      body: "<script>alert('body')</script>\n<b>bold</b>\n本文です"
    )

    get announcement_path(announcement)

    expected_title = "#{ERB::Util.html_escape(announcement.title)} | Recify"

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(document.at_css("title").text).to eq(expected_title)
      expect(meta_property("og:title")).to eq(expected_title)
      expect(meta_property("og:type")).to eq("article")
      expect(meta_name("description")).to eq("bold 本文です")
      expect(meta_property("og:description")).to eq("bold 本文です")
      expect(response.body).to include("&lt;script&gt;alert")
      expect(response.body).not_to include("<script>alert(\"title\")</script>")
      expect(response.body).not_to include("<script>alert('body')</script>")
    end
  end

  it "admin画面にはpublic OGP metaを出さない" do
    sign_in create(:user, admin: true)

    get admin_root_path

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(meta_property("og:title")).to be_nil
      expect(meta_name("twitter:card")).to be_nil
      expect(canonical_href).to be_nil
    end
  end
end
