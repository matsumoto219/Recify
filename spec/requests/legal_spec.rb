require 'rails_helper'

RSpec.describe 'Legal pages', type: :request do
  describe 'GET /terms' do
    def terms_section_titles
      I18n.t('legal.terms.sections').map { |section| section.fetch(:title) }
    end

    it '未ログインで利用規約shellを表示する' do
      expect(terms_path).to eq('/terms')

      get terms_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      sign_up_link = public_header&.at_css("a[href='#{new_user_registration_path}']")
      headings = document.css('h2').map { |heading| heading.text.squish }

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('legal.terms.title'))
        expect(response.body).not_to include('現在作成中の仮ページです')
        expect(response.body).not_to include('公開ページの導線と表示枠を確認するための仮ページ')
        expect(response.body).to include(I18n.t('legal.common.last_updated', date: I18n.t('legal.terms.last_updated_on')))
        expect(headings).to include(*terms_section_titles)
        expect(response.body).to include('本サービスの内容')
        expect(response.body).to include('ゲスト利用')
        expect(response.body).to include('レシート画像')
        expect(response.body).to include('解析処理')
        expect(response.body).to include('金額計算')
        expect(response.body).to include('税務、会計、法律')
        expect(response.body).to include('禁止事項')
        expect(response.body).to include('外部サービス')
        expect(response.body).to include('退会・データ削除')
        expect(response.body).to include('免責・責任制限')
        expect(response.body).to include('プライバシーポリシー')
        expect(response.body).to include('お問い合わせ')
        expect(response.body).not_to include('将来の有料機能')
        expect(response.body).not_to include('課金・決済機能')
        expect(response.body).not_to include('有料プラン')
        expect(response.body).not_to include('サブスクリプション')
        expect(response.body).not_to include('特定商取引法')
        expect(public_header).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(sign_up_link).to be_present
        expect(sign_up_link['class']).to include('btn-primary')
        expect(public_footer).to be_present
        expect(public_footer.at_css("a[href='#{contact_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{terms_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{privacy_path}']")).to be_present
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to include('作成中')
        expect(response.body).not_to include('正式な本文は公開前')
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'ログイン済みでもレシート一覧へリダイレクトせずpublic layoutで表示する' do
      sign_in create(:user)

      get terms_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      receipts_link = public_header&.at_css("a[href='#{receipts_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response).not_to redirect_to(receipts_path)
        expect(response.body).to include(I18n.t('legal.terms.title'))
        expect(response.body).not_to include('現在作成中の仮ページです')
        expect(public_header).to be_present
        expect(receipts_link).to be_present
        expect(receipts_link['class']).to include('btn-secondary')
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_nil
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_nil
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('id="desktop-sidebar"')
        expect(response.body).not_to include('作成中')
        expect(response.body).not_to include('正式な本文は公開前')
        expect(response.body).not_to include('translation missing')
      end
    end
  end

  describe 'GET /privacy' do
    def privacy_section_titles
      I18n.t('legal.privacy.sections').map { |section| section.fetch(:title) }
    end

    it '未ログインでプライバシーポリシーshellを表示する' do
      expect(privacy_path).to eq('/privacy')

      get privacy_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      public_footer = document.at_css('#public-footer')
      sign_up_link = public_header&.at_css("a[href='#{new_user_registration_path}']")
      headings = document.css('h2').map { |heading| heading.text.squish }

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t('legal.privacy.title'))
        expect(response.body).not_to include('現在作成中の仮ページです')
        expect(response.body).not_to include('公開ページの導線と表示枠を確認するための仮ページ')
        expect(response.body).to include(I18n.t('legal.common.last_updated', date: I18n.t('legal.privacy.last_updated_on')))
        expect(headings).to include(*privacy_section_titles)
        expect(response.body).to include('レシート画像')
        expect(response.body).to include('OCR処理')
        expect(response.body).to include('AI処理')
        expect(response.body).to include('外部サービス')
        expect(response.body).to include('保存期間と削除')
        expect(response.body).to include('Cookie')
        expect(response.body).to include('お問い合わせ')
        expect(public_header).to be_present
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_present
        expect(sign_up_link).to be_present
        expect(sign_up_link['class']).to include('btn-primary')
        expect(public_footer).to be_present
        expect(public_footer.at_css("a[href='#{contact_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{terms_path}']")).to be_present
        expect(public_footer.at_css("a[href='#{privacy_path}']")).to be_present
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('href="#"')
        expect(response.body).not_to include('作成中')
        expect(response.body).not_to include('正式な本文は公開前')
        expect(response.body).not_to include('translation missing')
      end
    end

    it 'ログイン済みでもレシート一覧へリダイレクトせずpublic layoutで表示する' do
      sign_in create(:user)

      get privacy_path
      document = Nokogiri::HTML(response.body)
      public_header = document.at_css('#public-header')
      receipts_link = public_header&.at_css("a[href='#{receipts_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(response).not_to redirect_to(receipts_path)
        expect(response.body).to include(I18n.t('legal.privacy.title'))
        expect(response.body).not_to include('現在作成中の仮ページです')
        expect(public_header).to be_present
        expect(receipts_link).to be_present
        expect(receipts_link['class']).to include('btn-secondary')
        expect(public_header.at_css("a[href='#{new_user_session_path}']")).to be_nil
        expect(public_header.at_css("a[href='#{new_user_registration_path}']")).to be_nil
        expect(response.body).not_to include('/home_lp.css')
        expect(response.body).not_to include('data-controller="home-reveal"')
        expect(response.body).not_to include('id="desktop-sidebar"')
        expect(response.body).not_to include('translation missing')
      end
    end
  end
end
