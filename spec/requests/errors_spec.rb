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

  def expect_error_page(status_code:, icon:, title:, primary_cta:, secondary_cta: nil)
    document = Nokogiri::HTML(response.body)

    aggregate_failures do
      expect(response).to have_http_status(status_code)
      expect(document.at_css('body')).to be_present
      expect(document.at_css('main')).to be_present
      expect(document.at_css('.material-symbols-outlined').text).to include(icon)
      expect(document.text).to include(title)
      expect(document.text).to include("Error Code: #{Rack::Utils.status_code(status_code)}")
      expect(document.at_css('a[href="' + receipts_path + '"]')).to have_attributes(text: include(primary_cta))
      expect(document.text).to include(secondary_cta) if secondary_cta.present?
      expect(document.text).to include('Recify')
      expect(document.text).to include('© 2026 Recify')
      expect(response.body).not_to match(/translation missing/i)
    end
  end

  describe 'direct error routes' do
    it 'GET /404 はRecify error layoutで表示される' do
      get '/404'

      expect_error_page(
        status_code: :not_found,
        icon: 'travel_explore',
        title: I18n.t('errors.not_found.title'),
        primary_cta: I18n.t('errors.not_found.primary_cta')
      )
    end

    it 'GET /422 はRecify error layoutで表示される' do
      get '/422'

      expect_error_page(
        status_code: :unprocessable_content,
        icon: 'error',
        title: I18n.t('errors.unprocessable.title'),
        primary_cta: I18n.t('errors.unprocessable.primary_cta')
      )
    end

    it 'GET /500 はRecify error layoutで表示される' do
      get '/500'

      expect_error_page(
        status_code: :internal_server_error,
        icon: 'cloud_off',
        title: I18n.t('errors.internal_server_error.title'),
        primary_cta: I18n.t('errors.internal_server_error.primary_cta'),
        secondary_cta: I18n.t('errors.internal_server_error.secondary_cta')
      )
    end
  end

  it '存在しないrouteはbranded 404になる' do
    get '/__recify_missing_route__'

    expect_error_page(
      status_code: :not_found,
      icon: 'travel_explore',
      title: I18n.t('errors.not_found.title'),
      primary_cta: I18n.t('errors.not_found.primary_cta')
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
      primary_cta: I18n.t('errors.not_found.primary_cta')
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
      primary_cta: I18n.t('errors.not_found.primary_cta')
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
      primary_cta: I18n.t('errors.not_found.primary_cta')
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
