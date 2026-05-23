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
end
