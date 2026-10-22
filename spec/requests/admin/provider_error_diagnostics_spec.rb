require 'rails_helper'

RSpec.describe 'Admin provider error diagnostics', type: :request do
  let(:admin) { create(:user, :admin) }
  let(:detail) do
    ExternalServices.error_detail(
      service: :ocr,
      provider: 'azure_document_intelligence',
      phase: :submit,
      http_status: 400,
      body: {
        error: {
          code: 'InvalidRequest',
          innererror: { code: 'InvalidContentLength', message: 'The input image is too large.' }
        }
      }
    )
  end

  it '解析runのsummaryから保存された内側の原因を管理者に表示する' do
    run = create(:receipt_analysis_run, :failed, ocr_summary: { provider_error_detail: detail })
    sign_in admin

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Provider causes', 'InvalidContentLength', 'The input image is too large.')
      expect(response.body).not_to include('translation missing')
    end
  end

  it 'summaryがない失敗でも保存済みerror metadataの原因を表示する' do
    run = create(
      :receipt_analysis_run,
      :failed,
      metadata: { error_metadata: { provider_detail: detail } }
    )
    sign_in admin

    get admin_receipt_analysis_run_path(run.run_key)

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('InvalidContentLength', 'The input image is too large.')
    end
  end

  it '管理ダッシュボードの更新応答にも同じ原因を表示する' do
    allow(ExternalServices).to receive(:status_snapshot).with(include_details: true).and_return(
      ocr: { state: 'down', last_error_code: 'ocr_api_error', last_error_detail: detail },
      ai: { state: 'ok' },
      upload: { allowed: false },
      notices: {}
    )
    sign_in admin

    get admin_external_services_status_path, as: :json

    aggregate_failures do
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch('html')).to include('InvalidContentLength', 'The input image is too large.')
    end
  end
end
