require 'rails_helper'

RSpec.describe 'service sanitizer boundary' do
  FORBIDDEN_VALUES = %w[
    LEAK_ACCESS_TOKEN_VALUE
    LEAK_REFRESH_TOKEN_VALUE
    LEAK_SET_COOKIE_VALUE
    LEAK_SUBSCRIPTION_KEY_VALUE
    LEAK_CLIENT_SECRET_VALUE
    LEAK_API_KEY_VALUE
    LEAK_AUTHORIZATION_VALUE
    LEAK_PROVIDER_RAW_RESPONSE_VALUE
    LEAK_PROMPT_VALUE
    LEAK_SYSTEM_PROMPT_VALUE
    LEAK_USER_PROMPT_VALUE
    LEAK_IMAGE_PAYLOAD_VALUE
    LEAK_ENDPOINT_VALUE
    LEAK_OPERATION_LOCATION_VALUE
    LEAK_NESTED_REFRESH_TOKEN_VALUE
    LEAK_ARRAY_SET_COOKIE_VALUE
  ].freeze

  def forbidden_payload
    {
      safe: 'visible',
      access_token: 'LEAK_ACCESS_TOKEN_VALUE',
      'refresh-token' => 'LEAK_REFRESH_TOKEN_VALUE',
      set_cookie: 'LEAK_SET_COOKIE_VALUE',
      subscription_key: 'LEAK_SUBSCRIPTION_KEY_VALUE',
      client_secret: 'LEAK_CLIENT_SECRET_VALUE',
      api_key: 'LEAK_API_KEY_VALUE',
      authorization: 'LEAK_AUTHORIZATION_VALUE',
      provider_raw_response: { body: 'LEAK_PROVIDER_RAW_RESPONSE_VALUE' },
      prompt: 'LEAK_PROMPT_VALUE',
      system_prompt: 'LEAK_SYSTEM_PROMPT_VALUE',
      user_prompt: 'LEAK_USER_PROMPT_VALUE',
      image_payload: 'LEAK_IMAGE_PAYLOAD_VALUE',
      endpoint: 'LEAK_ENDPOINT_VALUE',
      'operation-location' => 'LEAK_OPERATION_LOCATION_VALUE',
      nested: {
        safe: 'nested-visible',
        refresh_token: 'LEAK_NESTED_REFRESH_TOKEN_VALUE'
      },
      list: [
        {
          safe: 'array-visible',
          set_cookie: 'LEAK_ARRAY_SET_COOKIE_VALUE'
        }
      ]
    }
  end

  def expect_no_forbidden_values(value)
    serialized = JSON.generate(value)

    FORBIDDEN_VALUES.each do |forbidden_value|
      expect(serialized).not_to include(forbidden_value)
    end
  end

  it 'receipt analysis stored snapshotsからforbidden keyの値を除外する' do
    snapshot = Receipts::Processing::Runs::SnapshotBuilder.sanitized_stored_snapshot(forbidden_payload)

    aggregate_failures do
      expect(snapshot).to include('safe' => 'visible')
      expect(snapshot.dig('nested', 'safe')).to eq('nested-visible')
      expect(snapshot.dig('list', 0, 'safe')).to eq('array-visible')
      expect_no_forbidden_values(snapshot)
    end
  end

  it 'admin receipt analysis run表示用summary/detailからforbidden keyの値を除外する' do
    run = create(
      :receipt_analysis_run,
      :succeeded,
      ocr_summary: forbidden_payload,
      ocr_result_snapshot: forbidden_payload,
      ai_input_snapshot: forbidden_payload,
      ai_result_summary: forbidden_payload,
      ai_normalized_result_snapshot: forbidden_payload,
      final_result_summary: forbidden_payload,
      metadata: { build_params_snapshot: forbidden_payload }
    )
    run.receipt.update!(amount_calculation_profile: forbidden_payload)

    record = Admin.receipt_analysis_runs(receipt: run.receipt).records.first

    aggregate_failures do
      expect(record.dig(:summaries, :ocr, 'safe')).to eq('visible')
      expect(record.dig(:detailed_snapshots, :build_params_snapshot, 'safe')).to eq('visible')
      expect(record.dig(:amount_calculation_profile, 'safe')).to eq('visible')
      expect_no_forbidden_values(
        record.slice(:summaries, :detailed_snapshots, :amount_calculation_profile, :finalize_decision)
      )
    end
  end

  it 'audit logのmetadata / before_state / after_stateからforbidden keyの値を除外する' do
    log = AuditLogs.record_system_action!(
      action: 'receipt_analysis.sanitizer_boundary',
      outcome: 'succeeded',
      metadata: forbidden_payload,
      before_state: forbidden_payload,
      after_state: forbidden_payload
    )

    aggregate_failures do
      expect(log.metadata).to include('safe' => 'visible')
      expect(log.before_state).to include('safe' => 'visible')
      expect(log.after_state).to include('safe' => 'visible')
      expect_no_forbidden_values(log.attributes.slice('metadata', 'before_state', 'after_state'))
    end
  end

  it 'external service detailからheaders/bodyのforbidden keyの値を除外する' do
    detail = ExternalServices.error_detail(
      service: :ocr,
      provider: 'azure_document_intelligence',
      phase: :submit,
      http_status: 403,
      body: {
        error: {
          code: 'Forbidden',
          message: 'Authorization: Bearer LEAK_AUTHORIZATION_VALUE Ocp-Apim-Subscription-Key=LEAK_SUBSCRIPTION_KEY_VALUE'
        },
        provider_raw_response: 'LEAK_PROVIDER_RAW_RESPONSE_VALUE',
        prompt: 'LEAK_PROMPT_VALUE'
      },
      headers: {
        'operation-location' => 'LEAK_OPERATION_LOCATION_VALUE',
        'Ocp-Apim-Subscription-Key' => 'LEAK_SUBSCRIPTION_KEY_VALUE',
        'set-cookie' => 'LEAK_SET_COOKIE_VALUE',
        'apim-request-id' => 'safe-request-id'
      }
    )

    aggregate_failures do
      expect(detail).to include(request_id: 'safe-request-id')
      expect(detail.keys).not_to include(:headers, :body, :provider_raw_response, :prompt, :endpoint)
      expect_no_forbidden_values(detail)
    end
  end
end
