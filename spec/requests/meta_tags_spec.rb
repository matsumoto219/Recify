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

  def page_title
    document.at_css("title")&.text
  end

  def formatted_title(title)
    I18n.t("meta.title_format", title: title, site: I18n.t("meta.site_name"))
  end

  def accept_current_legal_documents_for(user)
    %i[terms privacy].each do |document_type|
      create(
        :legal_acceptance,
        user: user,
        legal_document: LegalDocument.current!(document_type, locale: :ja),
        document_type: document_type
      )
    end
  end

  shared_examples "indexable OGP meta" do |expected_title:, expected_description:, expected_path:, expected_type: "website"|
    it "index対象ページ用のOGP/Twitter/canonical metaを出す" do
      perform_request

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(document.at_css("html")["lang"]).to eq("ja")
        expect(document.at_css("title").text).to eq(expected_title)
        expect(meta_name("robots")).to eq("index, follow")
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

  shared_examples "noindex page" do
    it "noindexを明示し、canonical/OGP/Twitter metaを出さない" do
      perform_request

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(meta_name("robots")).to eq("noindex, nofollow")
        expect(meta_name("description")).to be_nil
        expect(meta_property("og:title")).to be_nil
        expect(meta_property("og:url")).to be_nil
        expect(meta_name("twitter:card")).to be_nil
        expect(canonical_href).to be_nil
        expect(response.body).not_to include("translation missing")
      end
    end
  end

  describe "GET /" do
    def perform_request
      get root_path
    end

    include_examples "indexable OGP meta",
                     expected_title: I18n.t("home.meta.title"),
                     expected_description: I18n.t("home.meta.description"),
                     expected_path: "/"
  end

  describe "GET /terms" do
    def perform_request
      get terms_path
    end

    include_examples "indexable OGP meta",
                     expected_title: "利用規約 | Recify",
                     expected_description: LegalDocuments::Repository.new.current!(document_type: :terms, locale: :ja).meta_description,
                     expected_path: "/terms"
  end

  describe "GET /privacy" do
    def perform_request
      get privacy_path
    end

    include_examples "indexable OGP meta",
                     expected_title: "プライバシーポリシー | Recify",
                     expected_description: LegalDocuments::Repository.new.current!(document_type: :privacy, locale: :ja).meta_description,
                     expected_path: "/privacy"
  end

  describe "GET /announcements" do
    def perform_request
      get announcements_path
    end

    include_examples "noindex page"
  end

  describe "GET /contact" do
    def perform_request
      get contact_path
    end

    include_examples "noindex page"
  end

  describe "GET /terms/versions" do
    def perform_request
      get terms_versions_path
    end

    include_examples "noindex page"
  end

  describe "GET /terms/versions/:version" do
    def perform_request
      get terms_version_path("2026-06-24")
    end

    include_examples "noindex page"
  end

  describe "GET /privacy/versions" do
    def perform_request
      get privacy_versions_path
    end

    include_examples "noindex page"
  end

  describe "GET /privacy/versions/:version" do
    def perform_request
      get privacy_version_path("2026-06-24")
    end

    include_examples "noindex page"
  end

  describe "GET /users/sign_in" do
    def perform_request
      get new_user_session_path
    end

    include_examples "noindex page"
  end

  describe "GET /users/sign_up" do
    def perform_request
      get new_user_registration_path
    end

    include_examples "noindex page"
  end

  describe "GET /users/password/new" do
    def perform_request
      get new_user_password_path
    end

    include_examples "noindex page"
  end

  describe "GET /users/confirmation/new" do
    def perform_request
      get new_user_confirmation_path
    end

    include_examples "noindex page"
  end

  describe "noindex一般画面のブラウザタイトル" do
    it "認証画面を固定titleで識別できる" do
      auth_pages = {
        new_user_session_path => "ログイン",
        new_user_registration_path => "新規登録",
        new_user_password_path => "パスワード再設定",
        edit_user_password_path(reset_password_token: "dummy-token") => "パスワード変更",
        new_user_confirmation_path => "確認メール再送",
        new_user_unlock_path => "アカウントロック解除"
      }

      auth_pages.each do |path, expected_title|
        get path

        aggregate_failures(path) do
          expect(response).to have_http_status(:ok)
          expect(page_title).to eq(formatted_title(expected_title))
          expect(meta_name("robots")).to eq("noindex, nofollow")
        end
      end
    end

    it "ログイン後の主要画面を固定titleで識別できる" do
      user = create(:user)
      receipt = create(:receipt, user: user, store_name: "Titleに出さない店舗名", total_amount: 12_345)
      accept_current_legal_documents_for(user)
      sign_in user

      app_pages = {
        settings_path => "設定",
        settings_account_path => "プロフィール設定",
        settings_security_path => "セキュリティ設定",
        new_settings_security_totp_path => "認証アプリ設定",
        receipts_path => "レシート一覧",
        select_input_method_receipts_path => "レシート登録方法",
        new_upload_receipts_path => "レシート画像をアップロード",
        new_receipt_path => "レシート手動登録",
        edit_receipt_path(receipt) => "レシート編集",
        receipt_path(receipt) => "レシート詳細",
        notifications_path => "通知"
      }

      app_pages.each do |path, expected_title|
        get path

        aggregate_failures(path) do
          expect(response).to have_http_status(:ok)
          expect(page_title).to eq(formatted_title(expected_title))
          expect(page_title).not_to include(receipt.store_name)
          expect(page_title).not_to include(receipt.display_id)
          expect(page_title).not_to include(user.email)
          expect(meta_name("robots")).to eq("noindex, nofollow")
        end
      end
    end
  end

  it "ログイン後のアプリ画面にはnoindexを出す" do
    user = create(:user)
    accept_current_legal_documents_for(user)
    sign_in user

    get receipts_path

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(meta_name("robots")).to eq("noindex, nofollow")
      expect(canonical_href).to be_nil
      expect(meta_property("og:title")).to be_nil
    end
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

  it "お知らせ詳細のHTML風文字列をescapeし、検索対象metaを出さない" do
    announcement = create(
      :announcement,
      :published,
      title: '<script>alert("title")</script>',
      body: "<script>alert('body')</script>\n<b>bold</b>\n本文です"
    )

    get announcement_path(announcement)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(meta_name("robots")).to eq("noindex, nofollow")
      expect(meta_property("og:title")).to be_nil
      expect(meta_name("description")).to be_nil
      expect(response.body).to include("&lt;script&gt;alert")
      expect(response.body).not_to include("<script>alert(\"title\")</script>")
      expect(response.body).not_to include("<script>alert('body')</script>")
    end
  end

  it "admin画面にはnoindexを出し、public OGP metaを出さない" do
    sign_in create(:user, admin: true)

    get admin_root_path

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(page_title).to eq("管理トップ")
      expect(meta_name("robots")).to eq("noindex, nofollow")
      expect(meta_property("og:title")).to be_nil
      expect(meta_name("twitter:card")).to be_nil
      expect(canonical_href).to be_nil
    end
  end
end
