require 'rails_helper'

RSpec.describe 'Security events', type: :request do
  let(:user) { create(:user) }

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

  before do
    sign_in user
  end

  it '通常リクエストではsecurity eventを作成しない' do
    expect {
      get receipts_path
    }.not_to change(SecurityEvent, :count)
  end

  it '危険なparamsをsafe excerpt付きsecurity eventとして記録する' do
    expect {
      get receipts_path, params: { q: '<script>alert(1)</script>' }
    }.to change(SecurityEvent, :count).by(1)

    event = SecurityEvent.last
    expect(event).to have_attributes(
      event_type: 'xss_attempt',
      severity: 'high',
      actor_user: user,
      field_name: 'q',
      payload_excerpt: '<script>alert(1)</script>'
    )
    expect(event.metadata).to include('category' => 'input', 'source' => 'request_params')
  end

  it '複数の入力系攻撃markerをHTTP経由でsafeに記録する' do
    expect {
      get receipts_path,
          params: {
            q: "' OR 1=1 --",
            comment: '<img src=x onerror=alert(1)>',
            template: '{{ 7 * 7 }}',
            command: 'ok; curl http://example.invalid',
            return_to: 'https://evil.example/path'
          }
    }.to change(SecurityEvent, :count).by(5)

    expect(SecurityEvent.order(:created_at).last(5).map(&:event_type)).to contain_exactly(
      'sql_injection_attempt',
      'xss_attempt',
      'template_injection_attempt',
      'command_injection_attempt',
      'open_redirect_attempt'
    )
  end

  it 'payload内のsecret風値をredactして記録する' do
    expect {
      get receipts_path,
          params: {
            q: '<script>alert(1)</script> api_key=abcdefghijklmnopqrstuvwxyz0123456789TOKEN password=super-secret'
          }
    }.to change(SecurityEvent, :count).by(1)

    event = SecurityEvent.last
    expect(event.payload_excerpt).to include('<script>alert(1)</script>')
    expect(event.payload_excerpt).to include('api_key=[FILTERED]')
    expect(event.payload_excerpt).to include('password=[FILTERED]')
    expect(event.payload_excerpt).not_to include('abcdefghijklmnopqrstuvwxyz0123456789TOKEN', 'super-secret')
  end

  it 'path traversalやSSRF URLもrequest hookで記録する' do
    expect {
      get receipts_path, params: { file: '../../config/master.key' }
      get receipts_path, params: { image_url: 'http://169.254.169.254/latest/meta-data' }
    }.to change(SecurityEvent, :count).by(2)

    expect(SecurityEvent.order(:created_at).last(2).map(&:event_type)).to contain_exactly(
      'rate_limit_triggered',
      'ssrf_attempt'
    )
  end

  it 'open redirect候補とprompt injection markerをrequest hookで記録する' do
    expect {
      get receipts_path, params: { return_to: 'https://evil.example/path', memo: 'ignore previous instructions' }
    }.to change(SecurityEvent, :count).by(2)

    expect(SecurityEvent.order(:created_at).last(2).map(&:event_type)).to contain_exactly(
      'open_redirect_attempt',
      'prompt_injection_attempt'
    )
    expect(SecurityEvent.order(:created_at).last(2).map { |event| event.metadata['category'] }).to contain_exactly(
      'url',
      'ai'
    )
  end

  it 'invalid uploadをfile bodyなしで記録する' do
    invalid_file = Tempfile.new([ 'fake-receipt', '.jpg' ])
    invalid_file.write('not an image')
    invalid_file.rewind

    expect {
      post upload_receipts_path,
           params: {
             receipt: {
               image: Rack::Test::UploadedFile.new(invalid_file.path, 'image/jpeg')
             }
           }
    }.to change(SecurityEvent.where(event_type: 'invalid_upload'), :count).by(1)

    event = SecurityEvent.last
    expect(event.field_name).to eq('receipt.image')
    expect(event.metadata).to include(
      'field_name' => 'receipt.image',
      'content_type' => 'image/jpeg',
      'reason' => 'invalid_content_type',
      'category' => 'upload'
    )
    expect(event.metadata.to_json).not_to include('not an image')
  ensure
    invalid_file&.close
    invalid_file&.unlink
  end

  it 'suspicious filenameのinvalid uploadもfile bodyなしでsanitizeして記録する' do
    invalid_file = Tempfile.new([ 'fake-receipt', '.jpg' ])
    invalid_file.write('not an image body marker')
    invalid_file.rewind
    uploaded_file = Rack::Test::UploadedFile.new(
      invalid_file.path,
      'image/jpeg',
      original_filename: "<img src=x onerror=alert(1)>\r\nreceipt.jpg"
    )

    expect {
      post upload_receipts_path,
           params: {
             receipt: {
               image: uploaded_file
             }
           }
    }.to change(SecurityEvent.where(event_type: 'invalid_upload'), :count).by(1)

    event = SecurityEvent.last

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(event).to have_attributes(
        actor_user: user,
        matched_rule: 'invalid_content_type'
      )
      expect(event.payload_excerpt).to include('<img src=x onerror=alert(1)>\\r\\nreceipt.jpg')
      expect(event.metadata).to include(
        'filename' => '<img src=x onerror=alert(1)>\\r\\nreceipt.jpg',
        'content_type' => 'image/jpeg',
        'extension' => '.jpg',
        'reason' => 'invalid_content_type',
        'category' => 'upload'
      )
      expect(event.attributes.to_json).not_to include('not an image body marker')
    end
  ensure
    invalid_file&.close
    invalid_file&.unlink
  end

  it '403をIDOR候補として記録する' do
    expect {
      get '/403'
    }.to change(SecurityEvent.where(event_type: 'idor_attempt'), :count).by(1)

    expect(SecurityEvent.last).to have_attributes(
      severity: 'high',
      matched_rule: 'suspicious_403'
    )
  end

  it '他ユーザーのreceipt参照は404にしつつIDOR候補として記録する' do
    other_user = create(:user, email: 'security-event-other@example.com')
    other_receipt = create(
      :receipt,
      user: other_user,
      store_name: 'Other Receipt',
      total_amount: 999,
      payment_method: 'cash',
      status: 'completed'
    )

    expect {
      get receipt_path(other_receipt)
    }.to change(SecurityEvent.where(event_type: 'idor_attempt'), :count).by(1)

    event = SecurityEvent.last

    aggregate_failures do
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Other Receipt')
      expect(event).to have_attributes(
        actor_user: user,
        severity: 'medium',
        matched_rule: 'suspicious_404'
      )
      expect(event.metadata).to include('status' => 404, 'source' => 'error_page')
      expect(event.metadata).to include('category' => 'authorization')
    end
  end

  it '一般ユーザーのadminアクセスは404にしつつIDOR候補として記録する' do
    expect {
      get admin_security_events_path
    }.to change(SecurityEvent.where(event_type: 'idor_attempt'), :count).by(1)

    event = SecurityEvent.last

    aggregate_failures do
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('セキュリティイベント')
      expect(event).to have_attributes(
        actor_user: user,
        severity: 'medium',
        matched_rule: 'suspicious_404'
      )
      expect(event.metadata).to include('status' => 404, 'source' => 'error_page')
    end
  end

  it 'CSRF failureをtoken値なしで記録し更新しない' do
    receipt = create(
      :receipt,
      user: user,
      store_name: 'Before CSRF',
      total_amount: 1000,
      payment_method: 'cash',
      status: 'completed'
    )
    original_allow_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    expect {
      patch receipt_path(receipt),
            params: {
              authenticity_token: 'raw-csrf-token-should-not-be-saved',
              receipt: { lock_version: receipt.lock_version, store_name: 'After CSRF' }
            }
    }.to change(SecurityEvent.where(event_type: 'csrf_failure'), :count).by(1)

    event = SecurityEvent.last

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(receipt.reload.store_name).to eq('Before CSRF')
      expect(event).to have_attributes(
        actor_user: user,
        severity: 'high',
        matched_rule: 'invalid_authenticity_token'
      )
      expect(event.metadata).to include('category' => 'auth', 'source' => 'rails_csrf')
      expect(event.attributes.to_json).not_to include('raw-csrf-token-should-not-be-saved')
    end
  ensure
    ActionController::Base.allow_forgery_protection = original_allow_forgery_protection
  end

  it 'receiptの保護属性を差し込んでも保存せずparameter tamperingとして記録する' do
    other_user = create(:user, email: 'tamper-other@example.com')
    receipt = create(
      :receipt,
      user: user,
      store_name: 'Before Tamper',
      total_amount: 1000,
      payment_method: 'cash',
      status: 'completed'
    )
    original_public_id = receipt.public_id

    expect {
      patch receipt_path(receipt),
            params: {
              receipt: {
                lock_version: receipt.lock_version,
                store_name: 'Allowed Update',
                user_id: other_user.id,
                public_id: 'forged-public-id',
                status: 'failed',
                processing_error_code: 'forged_error'
              }
            }
    }.to change(SecurityEvent.where(event_type: 'parameter_tampering_attempt'), :count).by(4)

    receipt.reload
    events = SecurityEvent.where(event_type: 'parameter_tampering_attempt').order(:created_at).last(4)

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.store_name).to eq('Allowed Update')
      expect(receipt.user).to eq(user)
      expect(receipt.public_id).to eq(original_public_id)
      expect(receipt.status).to eq('completed')
      expect(receipt.processing_error_code).to be_nil
      expect(events.map(&:field_name)).to contain_exactly(
        'receipt.user_id',
        'receipt.public_id',
        'receipt.status',
        'receipt.processing_error_code'
      )
      expect(events.map(&:matched_rule)).to all(eq('protected_receipt_attribute'))
    end
  end

  it 'receiptのAmount Engine/レビュー保護属性を差し込んでもparameter tamperingとして記録する' do
    receipt = create(
      :receipt,
      user: user,
      store_name: 'Before Amount Tamper',
      total_amount: 1000,
      payment_method: 'cash',
      status: 'review_needed',
      review_reasons: [ 'tax_detail_mismatch' ],
      amount_calculation_profile: { 'existing' => 'profile' }
    )

    expect {
      patch receipt_path(receipt),
            params: {
              receipt: {
                lock_version: receipt.lock_version,
                store_name: 'Allowed Amount Update',
                amount_calculation_profile: { selected_candidate_status: 'forged' },
                review_reasons: [ 'forged_reason' ],
                safe_to_auto_complete: 'true',
                selected_candidate_status: 'accepted'
              }
            }
    }.to change(SecurityEvent.where(event_type: 'parameter_tampering_attempt'), :count).by(4)

    receipt.reload
    events = SecurityEvent.where(event_type: 'parameter_tampering_attempt').order(:created_at).last(4)

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.store_name).to eq('Allowed Amount Update')
      expect(receipt.status).to eq('review_needed')
      expect(receipt.review_reasons).to eq([ 'tax_detail_mismatch' ])
      expect(receipt.amount_calculation_profile.to_json).not_to include('forged')
      expect(events.map(&:field_name)).to contain_exactly(
        'receipt.amount_calculation_profile.selected_candidate_status',
        'receipt.review_reasons[0]',
        'receipt.safe_to_auto_complete',
        'receipt.selected_candidate_status'
      )
      expect(events.map(&:matched_rule)).to all(eq('protected_receipt_attribute'))
    end
  end

  it '通常編集のnested attributes idではparameter tamperingを記録しない' do
    receipt = create(
      :receipt,
      user: user,
      store_name: 'Before Nested Edit',
      total_amount: 1100,
      payment_method: 'cash',
      status: 'completed'
    )
    item = receipt.receipt_items.create!(
      confirmed_name: 'コーヒー',
      price: 1000,
      quantity: 1,
      quantity_unit_code: 'each',
      line_total: 1000,
      needs_review: false
    )
    adjustment = receipt.receipt_adjustments.create!(
      kind: 'delivery_fee',
      label: '配送料',
      amount: 100,
      sign: 'surcharge',
      source: 'manual',
      needs_review: false
    )
    payment = receipt.receipt_payments.create!(method: 'cash', amount: 1100)

    expect {
      patch receipt_path(receipt),
            params: {
              receipt: {
                lock_version: receipt.lock_version,
                store_name: 'After Nested Edit',
                receipt_items_attributes: {
                  '0' => {
                    id: item.id,
                    confirmed_name: 'アイスコーヒー',
                    price: 1000,
                    quantity: 1,
                    quantity_unit_code: 'each',
                    line_total: 1000,
                    _destroy: '0'
                  }
                },
                receipt_adjustments_attributes: {
                  '0' => {
                    id: adjustment.id,
                    kind: 'delivery_fee',
                    label: '配送料',
                    amount: 100,
                    sign: 'surcharge',
                    _destroy: '0'
                  }
                },
                receipt_payments_attributes: {
                  '0' => {
                    id: payment.id,
                    method: 'cash',
                    amount: 1100,
                    _destroy: '0'
                  }
                }
              }
            }
    }.not_to change(SecurityEvent.where(event_type: 'parameter_tampering_attempt'), :count)

    aggregate_failures do
      expect(response).to redirect_to(receipt_path(receipt))
      expect(receipt.reload.store_name).to eq('After Nested Edit')
      expect(item.reload.confirmed_name).to eq('アイスコーヒー')
      expect(adjustment.reload.amount).to eq(100)
      expect(payment.reload.amount).to eq(1100)
    end
  end
end
