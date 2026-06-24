require 'rails_helper'

RSpec.describe 'Error pages', type: :request do
  around do |example|
    original_show_exceptions = Rails.application.env_config['action_dispatch.show_exceptions']
    original_show_detailed_exceptions = Rails.application.env_config['action_dispatch.show_detailed_exceptions']

    Rails.application.env_config['action_dispatch.show_exceptions'] = :all
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false

    example.run
  ensure
    Rails.application.env_config['action_dispatch.show_exceptions'] = original_show_exceptions
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_show_detailed_exceptions
  end

  def expect_error_page(status_code:, icon:, title:, primary_cta:, primary_href:, secondary_cta: nil)
    document = Nokogiri::HTML(response.body)

    aggregate_failures do
      expect(response).to have_http_status(status_code)
      expect(document.at_css('body')).to be_present
      expect(document.at_css('main')).to be_present
      expect(document.at_css('.material-symbols-outlined').text).to include(icon)
      expect(document.text).to include(title)
      expect(document.text).to include("Error Code: #{Rack::Utils.status_code(status_code)}")
      if primary_cta.present? && primary_href.present?
        expect(document.at_css('a[href="' + primary_href + '"]')).to have_attributes(text: include(primary_cta))
      end
      expect(document.text).to include(secondary_cta) if secondary_cta.present?
      expect(document.text).to include('Recify')
      expect(document.text).to include("© #{Time.current.year} Recify")
      expect(document.at_css('.brand-logo.error-footer-brand-logo')).to be_present
      expect(response.body).not_to match(/translation missing/i)
    end
  end

  def capture_error_page_logs(level)
    messages = []
    allow(Rails.logger).to receive(level) { |message| messages << message.to_s }
    messages
  end

  def error_support_id_text(request_id)
    "#{I18n.t('errors.internal_server_error.support_id_label')}: #{request_id}"
  end

  def expect_support_id(request_id)
    document = Nokogiri::HTML(response.body)
    support_id = document.at_css('[data-error-support-id]')

    aggregate_failures do
      expect(document.text).to include(I18n.t('errors.internal_server_error.support_message'))
      expect(support_id).to be_present
      if request_id.present?
        expect(support_id.text.squish).to eq(error_support_id_text(request_id))
      else
        expect(support_id.text.squish).to match(/\A#{I18n.t('errors.internal_server_error.support_id_label')}: \S+\z/)
      end
      expect(support_id['class']).to include('font-mono')
      expect(support_id['class']).to include('break-all')
    end
  end

  describe 'direct error routes' do
    it 'GET /404 はRecify error layoutで表示される' do
      get '/404'

      expect_error_page(
        status_code: :not_found,
        icon: 'travel_explore',
        title: I18n.t('errors.not_found.title'),
        primary_cta: nil,
        primary_href: nil
      )
      expect(Nokogiri::HTML(response.body).at_css('main a')).to be_nil
      expect(response.body).not_to include(new_user_session_path)
      expect(response.body).not_to include('問い合わせ時はこのIDをお知らせください')
    end

    it 'GET /403 はRecify error layoutで表示される' do
      get '/403'

      expect_error_page(
        status_code: :forbidden,
        icon: 'block',
        title: I18n.t('errors.forbidden.title'),
        primary_cta: nil,
        primary_href: nil
      )
      expect(response.body).to include(I18n.t('errors.forbidden.description'))
      expect(Nokogiri::HTML(response.body).at_css('main a')).to be_nil
      expect(response.body).not_to include(I18n.t('errors.common.signed_out_primary_cta'))
      expect(response.body).not_to include(new_user_session_path)
      expect(response.body).not_to include('問い合わせ時はこのIDをお知らせください')
    end

    it 'GET /422 はRecify error layoutで表示される' do
      get '/422'

      expect_error_page(
        status_code: :unprocessable_content,
        icon: 'error',
        title: I18n.t('errors.unprocessable.title'),
        primary_cta: I18n.t('errors.common.signed_out_primary_cta'),
        primary_href: new_user_session_path
      )
      expect(response.body).not_to include('問い合わせ時はこのIDをお知らせください')
    end

    it 'GET /500 はRecify error layoutで表示される' do
      get '/500'
      request_id = request.request_id

      expect_error_page(
        status_code: :internal_server_error,
        icon: 'cloud_off',
        title: I18n.t('errors.internal_server_error.title'),
        primary_cta: I18n.t('errors.common.signed_out_primary_cta'),
        primary_href: new_user_session_path,
        secondary_cta: I18n.t('errors.internal_server_error.secondary_cta')
      )
      expect_support_id(request_id)
    end

    it 'GET /503 はRecify error layoutで表示される' do
      get '/503'

      expect_error_page(
        status_code: :service_unavailable,
        icon: 'pause_circle',
        title: I18n.t('errors.service_unavailable.title'),
        primary_cta: nil,
        primary_href: nil
      )
      expect(response.body).to include('アクセス集中のため、サイトを一時的に停止しています。')
      expect(response.body).to include('しばらく時間をおいてから再度お試しください。')
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(response.headers['Retry-After']).to eq('300')
      expect(Nokogiri::HTML(response.body).at_css('main a')).to be_nil
    end

    it 'GET /503 はJSONリクエストに503 JSONを返す' do
      get '/503', headers: { 'ACCEPT' => 'application/json' }

      expect(response).to have_http_status(:service_unavailable)
      expect(response.media_type).to eq('application/json')
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(response.headers['Retry-After']).to eq('300')
      expect(JSON.parse(response.body)).to eq(
        'error' => I18n.t('errors.service_unavailable.title'),
        'message' => I18n.t('errors.service_unavailable.description'),
        'status' => 503,
        'retry_after' => 300
      )
    end

    it 'ログイン済みならGET /404はレシート一覧へ戻す' do
      sign_in create(:user)

      get '/404'

      expect_error_page(
        status_code: :not_found,
        icon: 'travel_explore',
        title: I18n.t('errors.not_found.title'),
        primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
        primary_href: receipts_path
      )
    end

    it 'ログイン済みならGET /422はレシート一覧へ戻す' do
      sign_in create(:user)

      get '/422'

      expect_error_page(
        status_code: :unprocessable_content,
        icon: 'error',
        title: I18n.t('errors.unprocessable.title'),
        primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
        primary_href: receipts_path
      )
    end

    it 'ログイン済みならGET /500はレシート一覧へ戻す' do
      sign_in create(:user)

      get '/500'
      request_id = request.request_id

      expect_error_page(
        status_code: :internal_server_error,
        icon: 'cloud_off',
        title: I18n.t('errors.internal_server_error.title'),
        primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
        primary_href: receipts_path,
        secondary_cta: I18n.t('errors.internal_server_error.secondary_cta')
      )
      expect_support_id(request_id)
    end

    it 'guestログイン時もGET /404はレシート一覧へ戻す' do
      sign_in create(:user, guest: true)

      get '/404'

      expect_error_page(
        status_code: :not_found,
        icon: 'travel_explore',
        title: I18n.t('errors.not_found.title'),
        primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
        primary_href: receipts_path
      )
    end
  end

  describe 'error page logging' do
    it '/404 到達時に最小項目をwarnで記録する' do
      messages = capture_error_page_logs(:warn)

      get '/404?token=secret'

      aggregate_failures do
        expect(messages.join("\n")).to include('[ErrorPage] status=404')
        expect(messages.join("\n")).to include('path=/404')
        expect(messages.join("\n")).to include('request_id=')
        expect(messages.join("\n")).to include('user_id=nil')
        expect(messages.join("\n")).to include('exception_class=nil')
        expect(messages.join("\n")).not_to include('token=secret')
      end
    end

    it '/422 到達時にwarnで記録する' do
      messages = capture_error_page_logs(:warn)

      get '/422'

      expect(messages.join("\n")).to include('[ErrorPage] status=422')
    end

    it 'ログイン済み404ではuser_idを記録する' do
      user = create(:user)
      messages = capture_error_page_logs(:warn)

      sign_in user
      get '/404'

      expect(messages.join("\n")).to include("user_id=#{user.id}")
    end

    it '他ユーザーreceipt参照の404ではoriginal pathを記録する' do
      user = create(:user)
      other_receipt = create(:receipt, :completed, user: create(:user))
      messages = capture_error_page_logs(:warn)

      sign_in user
      get receipt_path(other_receipt, token: 'secret')

      aggregate_failures do
        expect(messages.join("\n")).to include("[ErrorPage] status=404 path=#{receipt_path(other_receipt)}")
        expect(messages.join("\n")).not_to include('token=secret')
      end
    end

    it 'direct /500 はexceptionなしでもerrorで記録する' do
      messages = capture_error_page_logs(:error)

      get '/500'

      aggregate_failures do
        expect(messages.join("\n")).to include('[ErrorPage] status=500')
        expect(messages.join("\n")).to include('path=/500')
        expect(messages.join("\n")).to include('exception_class=nil')
      end
    end

    it 'direct /503 はwarnで記録する' do
      messages = capture_error_page_logs(:warn)

      get '/503'

      aggregate_failures do
        expect(messages.join("\n")).to include('[ErrorPage] status=503')
        expect(messages.join("\n")).to include('path=/503')
        expect(messages.join("\n")).to include('exception_class=nil')
      end
    end

    it '500 exceptionがある場合はclass/messageをerrorで記録する' do
      messages = capture_error_page_logs(:error)
      allow_any_instance_of(HomeController).to receive(:index).and_raise(RuntimeError, 'intentional failure for log')

      get root_path(token: 'secret')
      request_id = request.request_id

      aggregate_failures do
        expect(response).to have_http_status(:internal_server_error)
        expect(messages.join("\n")).to include('[ErrorPage] status=500 path=/')
        expect(messages.join("\n")).to include("request_id=#{request_id}")
        expect_support_id(request_id)
        expect(messages.join("\n")).to include('exception_class=RuntimeError')
        expect(messages.join("\n")).to include('exception_message=intentional failure for log')
        expect(response.body).not_to include('intentional failure for log')
        expect(response.body).not_to include('token=secret')
      end
    end
  end

  it '存在しないrouteはbranded 404になる' do
    get '/__recify_missing_route__'

    expect_error_page(
      status_code: :not_found,
      icon: 'travel_explore',
      title: I18n.t('errors.not_found.title'),
      primary_cta: nil,
      primary_href: nil
    )
    expect(Nokogiri::HTML(response.body).at_css('main a')).to be_nil
    expect(response.body).not_to include(new_user_session_path)
    expect(response.body).not_to include('問い合わせ時はこのIDをお知らせください')
  end

  it '他ユーザーのreceipt参照はbranded 404になる' do
    user = create(:user)
    other_receipt = create(:receipt, :completed, user: create(:user))

    sign_in user

    get receipt_path(other_receipt)

    expect_error_page(
      status_code: :not_found,
      icon: 'travel_explore',
      title: I18n.t('errors.not_found.title'),
      primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
      primary_href: receipts_path
    )
  end

  it 'Turbo requestのnot foundも現仕様どおりbranded 404になる' do
    user = create(:user)
    other_receipt = create(:receipt, :completed, user: create(:user))

    sign_in user

    get receipt_path(other_receipt), headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }

    expect_error_page(
      status_code: :not_found,
      icon: 'travel_explore',
      title: I18n.t('errors.not_found.title'),
      primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
      primary_href: receipts_path
    )
  end

  it '他ユーザーのnotification参照はbranded 404になる' do
    user = create(:user)
    other_notification = create(:notification, user: create(:user))

    sign_in user

    patch read_notification_path(other_notification)

    expect_error_page(
      status_code: :not_found,
      icon: 'travel_explore',
      title: I18n.t('errors.not_found.title'),
      primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
      primary_href: receipts_path
    )
  end

  it '既存form validation 422はglobal error pageへ飛ばさず元画面を維持する' do
    user = create(:user)
    invalid_file = Rack::Test::UploadedFile.new(
      Tempfile.create([ 'invalid', '.txt' ]).tap { |file| file.write('dummy'); file.rewind }.path,
      'text/plain'
    )

    sign_in user
    allow_any_instance_of(ActionView::Base).to receive(:image_tag).and_return('')

    post upload_receipts_path, params: { receipt: { image: invalid_file } }

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('receipts.new_upload.title'))
      expect(response.body).not_to include('Error Code: 422')
      expect(response.body).not_to match(/translation missing/i)
    end
  end

  describe 'proxy static fallback pages' do
    let(:static_error_pages) do
      {
        '400.html' => {
          code: '400',
          en_title: 'Bad Request - Recify',
          en_heading: 'Bad Request',
          en_message: 'The request could not be processed.',
          ja_heading: '不正なリクエストです'
        },
        '404.html' => {
          code: '404',
          en_title: 'Page Not Found - Recify',
          en_heading: 'Page Not Found',
          en_message: 'The page you are looking for could not be found.',
          ja_heading: 'ページが見つかりません'
        },
        '406-unsupported-browser.html' => {
          code: '406',
          en_title: 'Unsupported Browser - Recify',
          en_heading: 'Unsupported Browser',
          en_message: 'This browser is not supported. Please use an up-to-date browser.',
          ja_heading: 'このブラウザはサポートされていません'
        },
        '422.html' => {
          code: '422',
          en_title: 'Unprocessable Request - Recify',
          en_heading: 'Unprocessable Request',
          en_message: 'The request could not be processed. Please try again later.',
          ja_heading: '処理できませんでした'
        },
        '500.html' => {
          code: '500',
          en_title: 'Server Error - Recify',
          en_heading: 'Server Error',
          en_message: 'Something went wrong. Please try again later.',
          ja_heading: 'サーバーエラーが発生しました'
        },
        '502.html' => {
          code: '502',
          en_title: 'Connection Problem - Recify',
          en_heading: 'Connection Problem',
          en_message: 'The connection to the server is temporarily unstable. Please try again later.',
          ja_heading: '接続に問題が発生しています'
        },
        '503.html' => {
          code: '503',
          en_title: 'Temporarily Unavailable - Recify',
          en_heading: 'Temporarily Unavailable',
          en_message: 'The site is temporarily unavailable due to high traffic. Please try again later.',
          ja_heading: 'ただいま一時停止しています'
        },
        '504.html' => {
          code: '504',
          en_title: 'Gateway Timeout - Recify',
          en_heading: 'Gateway Timeout',
          en_message: 'The server is taking longer than expected to respond. Please try again later.',
          ja_heading: '応答に時間がかかっています'
        }
      }
    end

    it 'public/*.html static fallback pages default to English and keep Japanese fallback data' do
      static_error_pages.each do |filename, expected|
        static_page = Rails.root.join('public', filename)

        expect(static_page).to exist
        html = static_page.read
        document = Nokogiri::HTML(html)
        i18n_data = JSON.parse(document.at_css('script#error-page-i18n[type="application/json"]').text)

        aggregate_failures filename do
          expect(document.at_css('html')['lang']).to eq('en')
          expect(document.at_css('title').text).to eq(expected[:en_title])
          expect(document.at_css('[data-i18n-key="heading"]').text).to eq(expected[:en_heading])
          expect(document.at_css('[data-i18n-key="message"]').text).to eq(expected[:en_message])
          expect(i18n_data.dig('ja', 'pageTitle')).to end_with(' - Recify')
          expect(i18n_data.dig('ja', 'heading')).to eq(expected[:ja_heading])
          expect(i18n_data.dig('ja', 'message')).to be_present
          expect(html).to include("Error Code: #{expected[:code]}")
          expect(html).to include('color: var(--brand-primary);')
          expect(html).to include('background-image: linear-gradient(135deg, var(--brand-gradient-start), var(--brand-gradient-end));')
          expect(html).to include('background-clip: text;')
          expect(html).to include('color: var(--text-base);')
          expect(html).not_to include('text-wrap: balance')
          expect(document.at_css('footer .brand').text.squish).to eq('Recify')
          expect(document.at_css('footer .brand-mark')).to be_nil

          expect(html).to include('max-width: 36rem;') if filename == '406-unsupported-browser.html'

          if %w[502.html 503.html 504.html].include?(filename)
            expect(document.at_css('.icon svg')).to be_present
            expect(document.at_css('.icon').text.squish).to be_empty
          end
        end
      end
    end

    it 'static fallback language switch uses textContent without HTML injection' do
      static_error_pages.each_key do |filename|
        html = Rails.root.join('public', filename).read

        aggregate_failures filename do
          expect(html).to include('navigator.languages')
          expect(html).to include('navigator.language')
          expect(html).to include('startsWith("ja")')
          expect(html).to include('document.documentElement.lang = locale')
          expect(html).to include('textContent')
          expect(html).not_to include('innerHTML')
        end
      end
    end

    it 'proxy 5xx static pages remain no-store for Kamal proxy fallback' do
      %w[502.html 503.html 504.html].each do |filename|
        static_page = Rails.root.join('public', filename)

        expect(static_page).to exist
        expect(static_page.read).to include('no-store')
      end
    end

    it 'Kamal proxyへpublic配下の4xx/5xx静的エラーを配布できる' do
      config = YAML.safe_load_file(Rails.root.join('config/deploy.yml').to_s, aliases: true)

      expect(config['error_pages_path']).to eq('public')
      error_pages = Dir[Rails.root.join(config['error_pages_path'], '{4??.html,5??.html}')].map do |path|
        File.basename(path)
      end
      expect(error_pages).to include('502.html', '503.html', '504.html')
    end

    it 'ErrorPageStaticBypass は /503 を動的エラー画面へ渡す' do
      expect(Recify::ErrorPageStaticBypass::ERROR_ROUTES).to include(
        '/503' => '/errors/service_unavailable'
      )
    end
  end
end
