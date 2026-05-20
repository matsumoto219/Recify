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
      expect(document.at_css('a[href="' + primary_href + '"]')).to have_attributes(text: include(primary_cta))
      expect(document.text).to include(secondary_cta) if secondary_cta.present?
      expect(document.text).to include('Recify')
      expect(document.text).to include('© 2026 Recify')
      expect(response.body).not_to match(/translation missing/i)
    end
  end

  def capture_error_page_logs(level)
    messages = []
    allow(Rails.logger).to receive(level) { |message| messages << message.to_s }
    messages
  end

  describe 'direct error routes' do
    it 'GET /404 はRecify error layoutで表示される' do
      get '/404'

      expect_error_page(
        status_code: :not_found,
        icon: 'travel_explore',
        title: I18n.t('errors.not_found.title'),
        primary_cta: I18n.t('errors.common.signed_out_primary_cta'),
        primary_href: new_user_session_path
      )
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
    end

    it 'GET /500 はRecify error layoutで表示される' do
      get '/500'

      expect_error_page(
        status_code: :internal_server_error,
        icon: 'cloud_off',
        title: I18n.t('errors.internal_server_error.title'),
        primary_cta: I18n.t('errors.common.signed_out_primary_cta'),
        primary_href: new_user_session_path,
        secondary_cta: I18n.t('errors.internal_server_error.secondary_cta')
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

      expect_error_page(
        status_code: :internal_server_error,
        icon: 'cloud_off',
        title: I18n.t('errors.internal_server_error.title'),
        primary_cta: I18n.t('errors.common.signed_in_primary_cta'),
        primary_href: receipts_path,
        secondary_cta: I18n.t('errors.internal_server_error.secondary_cta')
      )
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

    it '500 exceptionがある場合はclass/messageをerrorで記録する' do
      messages = capture_error_page_logs(:error)
      allow_any_instance_of(HomeController).to receive(:index).and_raise(RuntimeError, 'intentional failure for log')

      get root_path

      aggregate_failures do
        expect(response).to have_http_status(:internal_server_error)
        expect(messages.join("\n")).to include('[ErrorPage] status=500 path=/')
        expect(messages.join("\n")).to include('exception_class=RuntimeError')
        expect(messages.join("\n")).to include('exception_message=intentional failure for log')
      end
    end
  end

  it '存在しないrouteはbranded 404になる' do
    get '/__recify_missing_route__'

    expect_error_page(
      status_code: :not_found,
      icon: 'travel_explore',
      title: I18n.t('errors.not_found.title'),
      primary_cta: I18n.t('errors.common.signed_out_primary_cta'),
      primary_href: new_user_session_path
    )
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
end
