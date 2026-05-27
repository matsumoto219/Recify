require 'rails_helper'

RSpec.describe Recify::SentrySanitizer do
  FakeRequest = Struct.new(:data, :headers, :cookies, :env, :query_string, keyword_init: true)
  FakeExceptionValue = Struct.new(:value, keyword_init: true)
  FakeException = Struct.new(:values, keyword_init: true)
  FakeEvent = Struct.new(:user, :extra, :contexts, :request, :exception, :attachments, keyword_init: true)

  it 'does not initialize Sentry in test without DSN' do
    expect(Sentry).not_to be_initialized
  end

  it 'keeps only user id from event user context' do
    event = FakeEvent.new(
      user: {
        id: 123,
        email: 'person@example.com',
        username: 'Person',
        ip_address: '203.0.113.1'
      }
    )

    described_class.sanitize_event(event)

    expect(event.user).to eq(id: 123)
  end

  it 'filters sensitive params, headers, cookies, OCR, AI, and image context' do
    event = FakeEvent.new(
      user: { id: 123, email: 'person@example.com' },
      extra: {
        email: 'customer@example.com',
        receipt_id: 42,
        active_job: {
          arguments: [ 'ocr raw text should not leak' ]
        },
        ocr_result: {
          lines: [ 'receipt line raw text' ],
          raw_text: 'OCR全文'
        },
        ai_raw_response: {
          response_body: '{"secret":"value"}',
          messages: [ { role: 'user', content: 'receipt prompt' } ]
        },
        receipt_image: {
          signed_id: 'signed-id',
          blob_key: 'blob-key'
        }
      },
      contexts: {
        request_payload: {
          prompt: 'analyze this receipt',
          filtered_content: 'OCR filtered text',
          api_key: 'sk-secret'
        }
      },
      request: FakeRequest.new(
        data: {
          user: {
            email: 'form@example.com',
            password: 'password'
          },
          receipt: {
            image: 'binary'
          }
        },
        headers: {
          'Authorization' => 'Bearer secret-token',
          'Cookie' => 'session=secret',
          'Content-Type' => 'application/json'
        },
        cookies: {
          session: 'secret'
        },
        env: {
          'HTTP_X_API_KEY' => 'secret',
          'SERVER_NAME' => 'example.com'
        },
        query_string: 'token=secret'
      ),
      exception: FakeException.new(
        values: [
          FakeExceptionValue.new(value: 'OpenAI failed for customer@example.com token=secret')
        ]
      ),
      attachments: [ 'receipt.jpg' ]
    )

    described_class.sanitize_event(event)

    aggregate_failures do
      expect(event.user).to eq(id: 123)
      expect(event.attachments).to eq([])
      expect(event.extra[:email]).to eq(described_class::FILTERED)
      expect(event.extra[:receipt_id]).to eq(42)
      expect(event.extra[:active_job][:arguments]).to eq(described_class::FILTERED)
      expect(event.extra[:ocr_result]).to eq(described_class::FILTERED)
      expect(event.extra[:ai_raw_response]).to eq(described_class::FILTERED)
      expect(event.extra[:receipt_image]).to eq(described_class::FILTERED)
      expect(event.contexts[:request_payload][:prompt]).to eq(described_class::FILTERED)
      expect(event.contexts[:request_payload][:filtered_content]).to eq(described_class::FILTERED)
      expect(event.contexts[:request_payload][:api_key]).to eq(described_class::FILTERED)
      expect(event.request.data[:user][:email]).to eq(described_class::FILTERED)
      expect(event.request.data[:user][:password]).to eq(described_class::FILTERED)
      expect(event.request.data[:receipt][:image]).to eq(described_class::FILTERED)
      expect(event.request.headers['Authorization']).to eq(described_class::FILTERED)
      expect(event.request.headers['Cookie']).to eq(described_class::FILTERED)
      expect(event.request.headers['Content-Type']).to eq('application/json')
      expect(event.request.cookies).to eq(described_class::FILTERED)
      expect(event.request.env['HTTP_X_API_KEY']).to eq(described_class::FILTERED)
      expect(event.request.env['SERVER_NAME']).to eq('example.com')
      expect(event.request.query_string).to be_nil
      expect(event.exception.values.first.value).not_to include('customer@example.com', 'secret')
    end
  end

  it 'filters raw request body strings completely' do
    request = FakeRequest.new(data: '{"email":"person@example.com","raw_text":"OCR"}')
    event = FakeEvent.new(request: request)

    described_class.sanitize_event(event)

    expect(event.request.data).to eq(described_class::FILTERED)
  end

  it 'filters authentication and digest material recursively while preserving safe counts' do
    event = FakeEvent.new(
      extra: {
        credential_id: 'credential-id',
        challenge: 'challenge',
        session_uid: 'raw-session-uid',
        session_uid_digest: 'session-digest',
        code_digest: 'code-digest',
        recovery_code: 'recovery-code',
        recovery_codes_count: 2,
        backup_codes_count: 1,
        nested: {
          credentialId: 'camel-credential-id',
          sessionUid: 'camel-session-uid',
          sessionUidDigest: 'camel-session-digest',
          codeDigest: 'camel-code-digest'
        },
        array: [
          {
            challenge: 'array-challenge',
            recoveryCode: 'array-recovery-code'
          }
        ]
      },
      contexts: {
        security: {
          publicKey: 'public-key',
          totpSecret: 'totp-secret',
          provisioningUri: 'otpauth://totp/Recify',
          rawResponse: 'raw-response'
        }
      }
    )

    described_class.sanitize_event(event)

    aggregate_failures do
      expect(event.extra[:credential_id]).to eq(described_class::FILTERED)
      expect(event.extra[:challenge]).to eq(described_class::FILTERED)
      expect(event.extra[:session_uid]).to eq(described_class::FILTERED)
      expect(event.extra[:session_uid_digest]).to eq(described_class::FILTERED)
      expect(event.extra[:code_digest]).to eq(described_class::FILTERED)
      expect(event.extra[:recovery_code]).to eq(described_class::FILTERED)
      expect(event.extra[:recovery_codes_count]).to eq(2)
      expect(event.extra[:backup_codes_count]).to eq(1)
      expect(event.extra[:nested][:credentialId]).to eq(described_class::FILTERED)
      expect(event.extra[:nested][:sessionUid]).to eq(described_class::FILTERED)
      expect(event.extra[:nested][:sessionUidDigest]).to eq(described_class::FILTERED)
      expect(event.extra[:nested][:codeDigest]).to eq(described_class::FILTERED)
      expect(event.extra[:array].first[:challenge]).to eq(described_class::FILTERED)
      expect(event.extra[:array].first[:recoveryCode]).to eq(described_class::FILTERED)
      expect(event.contexts[:security][:publicKey]).to eq(described_class::FILTERED)
      expect(event.contexts[:security][:totpSecret]).to eq(described_class::FILTERED)
      expect(event.contexts[:security][:provisioningUri]).to eq(described_class::FILTERED)
      expect(event.contexts[:security][:rawResponse]).to eq(described_class::FILTERED)
    end
  end
end
