require 'rails_helper'

RSpec.describe 'External services status', type: :request do
  let(:user) { create(:user) }
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    sign_in user
  end

  describe 'GET /external_services/status' do
    it 'OCR/AI状態とupload可否をJSONで返す' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return(
        state: 'down',
        monitoring: true,
        last_checked_at: '2026-05-19T10:00:00Z',
        next_check_at: '2026-05-19T10:30:00Z'
      )
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return(
        state: 'down',
        monitoring: true,
        last_checked_at: '2026-05-19T10:05:00Z',
        next_check_at: '2026-05-19T10:35:00Z'
      )

      get external_services_status_path, as: :json

      json = response.parsed_body

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(json.dig('ocr', 'state')).to eq('down')
        expect(json.dig('ocr', 'monitoring')).to eq(true)
        expect(json.dig('ocr', 'checked_at')).to eq('2026-05-19T10:00:00Z')
        expect(json.dig('ocr', 'last_checked_at')).to eq('2026-05-19T10:00:00Z')
        expect(json.dig('ocr', 'next_check_at')).to eq('2026-05-19T10:30:00Z')
        expect(json.dig('ocr', 'message')).to eq(I18n.t('flash.receipts.ocr_unavailable'))
        expect(json.dig('ocr', 'badge_html')).to include(I18n.t('shared.service_status.down'))
        expect(json.dig('ai', 'state')).to eq('down')
        expect(json.dig('ai', 'message')).to eq(I18n.t('receipts.new_upload.ai_down'))
        expect(json.dig('upload', 'allowed')).to eq(false)
        expect(json.dig('upload', 'ocr_available')).to eq(false)
      end
    end

    it 'OCR復旧時はupload可として返す' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return(
        state: 'ok',
        monitoring: false,
        last_checked_at: nil,
        next_check_at: nil
      )
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return(
        state: 'ok',
        monitoring: false,
        last_checked_at: nil,
        next_check_at: nil
      )

      get external_services_status_path, as: :json

      json = response.parsed_body

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(json.dig('ocr', 'state')).to eq('ok')
        expect(json.dig('ai', 'state')).to eq('ok')
        expect(json.dig('upload', 'allowed')).to eq(true)
        expect(json.dig('upload', 'ocr_available')).to eq(true)
      end
    end

    it '未ログインではログイン画面へリダイレクトする' do
      sign_out user

      get external_services_status_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe 'POST /debug/external_services/:service/:state' do
    before do
      allow(Rails).to receive(:cache).and_return(cache_store)
      Rails.cache.clear
    end

    after do
      Rails.cache.clear
    end

    it 'dev/test用にOCR down状態へ切り替えられる' do
      post debug_external_service_state_path(service: 'ocr', state: 'down'),
           params: { reason: 'browser reproduction' },
           as: :json

      json = response.parsed_body

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(json['ok']).to eq(true)
        expect(json['service']).to eq('ocr')
        expect(json['requested_state']).to eq('down')
        expect(json['actor_id']).to eq(user.id)
        expect(json.dig('snapshot', 'state')).to eq('down')
        expect(ExternalServiceStatus.down?(:ocr)).to eq(true)
      end
    end

    it 'OCR down状態にするとstatusでupload不可になる' do
      post debug_external_service_state_path(service: 'ocr', state: 'down'), as: :json

      get external_services_status_path, as: :json

      json = response.parsed_body

      aggregate_failures do
        expect(json.dig('ocr', 'state')).to eq('down')
        expect(json.dig('upload', 'allowed')).to eq(false)
        expect(json.dig('upload', 'ocr_available')).to eq(false)
        expect(json.dig('notices', 'ocr_down')).to eq(true)
      end
    end

    it 'AI down状態にするとstatusでOCR-only fallback noticeが出る' do
      post debug_external_service_state_path(service: 'ai', state: 'down'), as: :json

      get external_services_status_path, as: :json

      json = response.parsed_body

      aggregate_failures do
        expect(json.dig('ai', 'state')).to eq('down')
        expect(json.dig('ai', 'message')).to eq(I18n.t('receipts.new_upload.ai_down'))
        expect(json.dig('upload', 'allowed')).to eq(true)
        expect(json.dig('upload', 'ocr_available')).to eq(true)
        expect(json.dig('notices', 'ai_down')).to eq(true)
      end
    end

    it '不正serviceを弾く' do
      post debug_external_service_state_path(service: 'storage', state: 'down'), as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['ok']).to eq(false)
        expect(response.parsed_body['error']).to eq('Unsupported service: storage')
      end
    end

    it '不正stateを弾く' do
      post debug_external_service_state_path(service: 'ocr', state: 'offline'), as: :json

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body['ok']).to eq(false)
        expect(response.parsed_body['error']).to eq('Unsupported state: offline')
      end
    end

    it 'production相当ではdebug routeを実行できない' do
      allow(ExternalServices::DebugStateSwitcher).to receive(:available?).and_return(false)

      post debug_external_service_state_path(service: 'ocr', state: 'down'), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'polling DOM hooks' do
    before do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'down' })
    end

    it 'upload画面にpolling controllerと更新targetを描画する' do
      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-controller~="service-status-polling"]')).to be_present
        expect(document.at_css('[data-service-status-polling-status-url-value]')['data-service-status-polling-status-url-value']).to eq(external_services_status_path)
        expect(document.at_css('[data-service-status-polling-target="uploadRoot"]')).to be_present
        expect(document.css('[data-service-status-polling-target="serviceNotice"]').size).to be >= 2
      end
    end

    it '登録方法選択画面にpolling controllerとOCR導線targetを描画する' do
      get select_input_method_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-controller~="service-status-polling"]')).to be_present
        expect(document.at_css('[data-service-status-polling-target="ocrGatedLink"]')).to be_present
        expect(document.at_css('[data-service-status-polling-target="ocrGatedLink"]')['data-enabled-href']).to eq(new_upload_receipts_path)
      end
    end

    it 'settings画面にpolling controllerとservice badge targetを描画する' do
      get settings_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-controller~="service-status-polling"]')).to be_present
        expect(document.css('[data-service-status-polling-target="serviceBadge"]').map { |node| node['data-service'] }).to contain_exactly('ocr', 'ai')
      end
    end
  end
end
