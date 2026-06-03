require 'rails_helper'

RSpec.describe Ocr::Client do
  let(:image_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:image) { Rack::Test::UploadedFile.new(image_path, 'image/jpeg') }
  let(:provider) { 'azure_document_intelligence' }
  let(:client) { described_class.new(image: image, provider: provider) }
  let(:operational_env_keys) do
    %w[
      AZURE_OCR_TIMEOUT
      AZURE_OCR_MAX_POLL
      AZURE_OCR_POLL_INTERVAL
      AZURE_OCR_MAX_RETRIES
      AZURE_OCR_BASE_RETRY_DELAY
      AZURE_OCR_MAX_RETRY_DELAY
    ]
  end
  let(:operation_location) do
    'https://example.cognitiveservices.azure.com/documentintelligence/documentModels/prebuilt-receipt/analyzeResults/123'
  end
  let(:succeeded_response) do
    {
      'status' => 'succeeded',
      'analyzeResult' => {
        'content' => 'sample receipt content',
        'documents' => [
          {
            'fields' => {
              'MerchantName' => { 'valueString' => 'Test Store' },
              'Total' => { 'valueCurrency' => { 'amount' => 1280 } }
            }
          }
        ]
      }
    }
  end
  let(:accepted_response) do
    faraday_response(status: 202, headers: { 'operation-location' => operation_location })
  end

  def faraday_response(status:, headers: {}, body: '{}')
    instance_double(Faraday::Response, status: status, headers: headers, body: body)
  end

  def request_double
    Struct.new(:headers, :body) do
      def url(value)
        @url = value
      end
    end.new({})
  end

  def stub_connection_post(target_client, *outcomes)
    connection = instance_double(Faraday::Connection)
    remaining_outcomes = outcomes.dup

    allow(target_client).to receive(:connection).and_return(connection)
    allow(connection).to receive(:post) do |&block|
      block.call(request_double)
      outcome = remaining_outcomes.shift
      raise outcome if outcome.is_a?(Exception)

      outcome
    end

    connection
  end

  def with_env(overrides)
    previous_values = overrides.keys.to_h do |key|
      [ key, ENV.key?(key) ? ENV[key] : :__unset__ ]
    end

    overrides.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous_values.each do |key, value|
      if value == :__unset__
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end

  around do |example|
    with_env(operational_env_keys.to_h { |key| [ key, nil ] }) do
      example.run
    end
  end

  before do
    allow(client).to receive(:retry_jitter_delay).and_return(0.0)
  end

  describe '#call' do
    before do
      allow(client).to receive(:submit_request).and_return(operation_location)
    end

    it 'submit_request の結果を使って poll_result を呼び、生レスポンスHashを返す' do
      allow(client).to receive(:poll_result).with(operation_location).and_return(succeeded_response)

      result = client.call

      aggregate_failures do
        expect(client).to have_received(:submit_request)
        expect(client).to have_received(:poll_result).with(operation_location)
        expect(result).to eq(succeeded_response)
        expect(result['status']).to eq('succeeded')
        expect(result.dig('analyzeResult', 'documents', 0, 'fields', 'MerchantName', 'valueString')).to eq('Test Store')
      end
    end

    it 'Faraday::TimeoutError は OcrTimeoutError(ocr_timeout) に変換する' do
      allow(client).to receive(:submit_request).and_raise(Faraday::TimeoutError.new('timeout'))

      expect do
        client.call
      end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')
    end

    it 'Faraday::ConnectionFailed は OcrError(external_service_unavailable) に変換する' do
      allow(client).to receive(:submit_request).and_raise(Faraday::ConnectionFailed.new('connection failed'))

      expect do
        client.call
      end.to raise_error(Ocr::OcrError, 'external_service_unavailable')
    end

    it '想定外例外は OcrError(unexpected_error) に変換する' do
      allow(client).to receive(:submit_request).and_raise(StandardError.new('boom'))

      expect do
        client.call
      end.to raise_error(Ocr::OcrError, 'unexpected_error')
    end
  end

  describe '#submit_request' do
    it 'prebuilt receipt analyze requestにPaymentMethods query fieldを指定する' do
      analyze_path = client.send(:analyze_path)
      uri = URI.parse("https://example.test#{analyze_path}")
      query = Rack::Utils.parse_nested_query(uri.query)

      aggregate_failures do
        expect(uri.path).to eq('/documentintelligence/documentModels/prebuilt-receipt:analyze')
        expect(query).to include(
          'api-version' => '2024-11-30',
          'features' => 'queryFields',
          'queryFields' => 'PaymentMethods'
        )
      end
    end

    it '429が1回出た後に成功したらretryしてoperation-locationを返す' do
      connection = stub_connection_post(
        client,
        faraday_response(status: 429),
        accepted_response
      )
      allow(client).to receive(:sleep)

      result = client.send(:submit_request)

      aggregate_failures do
        expect(result).to eq(operation_location)
        expect(connection).to have_received(:post).twice
        expect(client).to have_received(:sleep).with(0.5).once
      end
    end

    it '429のRetry-After秒数をretry delayとして優先する' do
      connection = stub_connection_post(
        client,
        faraday_response(status: 429, headers: { 'Retry-After' => '3' }),
        accepted_response
      )
      allow(client).to receive(:sleep)

      result = client.send(:submit_request)

      aggregate_failures do
        expect(result).to eq(operation_location)
        expect(connection).to have_received(:post).twice
        expect(client).to have_received(:sleep).with(3.0).once
      end
    end

    it '不正なRetry-Afterは通常backoffへfallbackする' do
      connection = stub_connection_post(
        client,
        faraday_response(status: 429, headers: { 'Retry-After' => 'later' }),
        accepted_response
      )
      allow(client).to receive(:sleep)

      result = client.send(:submit_request)

      aggregate_failures do
        expect(result).to eq(operation_location)
        expect(connection).to have_received(:post).twice
        expect(client).to have_received(:sleep).with(0.5).once
      end
    end

    it 'Retry-Afterがない場合はjitterを加算する' do
      connection = stub_connection_post(
        client,
        faraday_response(status: 429),
        accepted_response
      )
      allow(client).to receive(:retry_jitter_delay).and_return(0.25)
      allow(client).to receive(:sleep)

      result = client.send(:submit_request)

      aggregate_failures do
        expect(result).to eq(operation_location)
        expect(connection).to have_received(:post).twice
        expect(client).to have_received(:sleep).with(0.75).once
      end
    end

    it 'Retry-Afterが上限を超える場合はcapする' do
      connection = stub_connection_post(
        client,
        faraday_response(status: 429, headers: { 'Retry-After' => '30' }),
        accepted_response
      )
      allow(client).to receive(:sleep)

      result = client.send(:submit_request)

      aggregate_failures do
        expect(result).to eq(operation_location)
        expect(connection).to have_received(:post).twice
        expect(client).to have_received(:sleep).with(10.0).once
      end
    end

    it 'HTTP 408が1回出た後に成功したらretryする' do
      connection = stub_connection_post(
        client,
        faraday_response(status: 408),
        accepted_response
      )
      allow(client).to receive(:sleep)

      result = client.send(:submit_request)

      aggregate_failures do
        expect(result).to eq(operation_location)
        expect(connection).to have_received(:post).twice
        expect(client).to have_received(:sleep).with(0.5).once
      end
    end

    it '5xxがretry上限を超えたら external_service_unavailable を投げる' do
      connection = stub_connection_post(
        client,
        faraday_response(status: 500),
        faraday_response(status: 500),
        faraday_response(status: 500)
      )
      allow(client).to receive(:sleep)

      expect do
        client.send(:submit_request)
      end.to raise_error(Ocr::OcrError, 'external_service_unavailable')

      aggregate_failures do
        expect(connection).to have_received(:post).exactly(3).times
        expect(client).to have_received(:sleep).with(0.5).once
        expect(client).to have_received(:sleep).with(1.0).once
      end
    end

    it 'submit POST の Faraday::TimeoutError はretryしない' do
      connection = stub_connection_post(client, Faraday::TimeoutError.new('timeout'))
      allow(client).to receive(:sleep)

      expect do
        client.send(:submit_request)
      end.to raise_error(Faraday::TimeoutError)

      aggregate_failures do
        expect(connection).to have_received(:post).once
        expect(client).not_to have_received(:sleep)
      end
    end

    it 'Faraday::ConnectionFailed はretryする' do
      connection = stub_connection_post(
        client,
        Faraday::ConnectionFailed.new('connection failed'),
        accepted_response
      )
      allow(client).to receive(:sleep)

      result = client.send(:submit_request)

      aggregate_failures do
        expect(result).to eq(operation_location)
        expect(connection).to have_received(:post).twice
        expect(client).to have_received(:sleep).with(0.5).once
      end
    end

    it '401/403はretryしない' do
      [ 401, 403 ].each do |status|
        request_client = described_class.new(image: image, provider: provider)
        connection = stub_connection_post(request_client, faraday_response(status: status))
        allow(request_client).to receive(:sleep)

        expect do
          request_client.send(:submit_request)
        end.to raise_error(Ocr::OcrError, 'external_service_auth_error')

        aggregate_failures do
          expect(connection).to have_received(:post).once
          expect(request_client).not_to have_received(:sleep)
        end
      end
    end

    it '404/input_invalidはretryしない' do
      connection = stub_connection_post(client, faraday_response(status: 404))
      allow(client).to receive(:sleep)

      expect do
        client.send(:submit_request)
      end.to raise_error(Ocr::OcrError, 'input_invalid')

      aggregate_failures do
        expect(connection).to have_received(:post).once
        expect(client).not_to have_received(:sleep)
      end
    end

    it '422/ocr_api_errorはretryしない' do
      connection = stub_connection_post(client, faraday_response(status: 422))
      allow(client).to receive(:sleep)

      expect do
        client.send(:submit_request)
      end.to raise_error(Ocr::OcrError, 'ocr_api_error')

      aggregate_failures do
        expect(connection).to have_received(:post).once
        expect(client).not_to have_received(:sleep)
      end
    end

    it 'operation-location欠落はretryしない' do
      connection = stub_connection_post(client, faraday_response(status: 202, headers: {}))
      allow(client).to receive(:sleep)

      expect do
        client.send(:submit_request)
      end.to raise_error(Ocr::OcrError, 'ocr_invalid_response')

      aggregate_failures do
        expect(connection).to have_received(:post).once
        expect(client).not_to have_received(:sleep)
      end
    end
  end

  describe 'operational ENV settings' do
    it 'AZURE_OCR_TIMEOUTでFaraday timeoutを上書きできる' do
      with_env(
        'AZURE_OCR_ENDPOINT' => 'https://example.cognitiveservices.azure.com',
        'AZURE_OCR_TIMEOUT' => '45'
      ) do
        connection = client.send(:connection)

        expect(connection.options.timeout).to eq(45)
      end
    end

    it 'AZURE_OCR_MAX_POLLとAZURE_OCR_POLL_INTERVALでpolling上限を上書きできる' do
      with_env(
        'AZURE_OCR_MAX_POLL' => '2',
        'AZURE_OCR_POLL_INTERVAL' => '0.25'
      ) do
        running_response = faraday_response(status: 200, body: JSON.generate({ 'status' => 'running' }))
        allow(Faraday).to receive(:get).and_return(running_response)
        allow(client).to receive(:sleep)

        expect do
          client.send(:poll_result, operation_location)
        end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')

        aggregate_failures do
          expect(Faraday).to have_received(:get).twice
          expect(client).to have_received(:sleep).with(0.25).twice
        end
      end
    end

    it 'AZURE_OCR_MAX_RETRIESでretry上限を上書きできる' do
      with_env('AZURE_OCR_MAX_RETRIES' => '0') do
        connection = stub_connection_post(client, faraday_response(status: 429))
        allow(client).to receive(:sleep)

        expect do
          client.send(:submit_request)
        end.to raise_error(Ocr::OcrError, 'external_service_unavailable')

        aggregate_failures do
          expect(connection).to have_received(:post).once
          expect(client).not_to have_received(:sleep)
        end
      end
    end

    it 'AZURE_OCR_BASE_RETRY_DELAYとAZURE_OCR_MAX_RETRY_DELAYでretry delayを上書きできる' do
      with_env(
        'AZURE_OCR_BASE_RETRY_DELAY' => '2.0',
        'AZURE_OCR_MAX_RETRY_DELAY' => '3.0'
      ) do
        allow(client).to receive(:retry_jitter_delay).and_return(0.25)

        aggregate_failures do
          expect(client.send(:retry_delay_for, 1)).to eq(2.25)
          expect(client.send(:retry_delay_for, 3)).to eq(3.0)
        end
      end
    end
  end

  describe '#poll_result' do
    let(:succeeded_poll_response) do
      faraday_response(status: 200, body: JSON.generate(succeeded_response))
    end

    it 'polling GET の Faraday::TimeoutError はretryする' do
      outcomes = [
        Faraday::TimeoutError.new('timeout'),
        succeeded_poll_response
      ]
      allow(Faraday).to receive(:get) do
        outcome = outcomes.shift
        raise outcome if outcome.is_a?(Exception)

        outcome
      end
      allow(client).to receive(:sleep)

      result = client.send(:poll_result, operation_location)

      aggregate_failures do
        expect(result).to eq(succeeded_response)
        expect(Faraday).to have_received(:get).twice
        expect(client).to have_received(:sleep).with(0.5).once
      end
    end

    it 'polling GET の一時失敗ではsubmit_requestを再実行しない' do
      connection = stub_connection_post(client, accepted_response)
      outcomes = [
        faraday_response(status: 500),
        succeeded_poll_response
      ]
      allow(Faraday).to receive(:get) do
        outcome = outcomes.shift
        raise outcome if outcome.is_a?(Exception)

        outcome
      end
      allow(client).to receive(:sleep)

      result = client.call

      aggregate_failures do
        expect(result).to eq(succeeded_response)
        expect(connection).to have_received(:post).once
        expect(Faraday).to have_received(:get).twice
        expect(client).to have_received(:sleep).with(0.5).once
      end
    end

    it 'MAX_POLL超過の ocr_timeout はretryしない' do
      running_response = faraday_response(status: 200, body: JSON.generate({ 'status' => 'running' }))
      allow(Faraday).to receive(:get).and_return(running_response)
      allow(client).to receive(:sleep)

      expect do
        client.send(:poll_result, operation_location)
      end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')

      aggregate_failures do
        expect(Faraday).to have_received(:get).exactly(described_class::MAX_POLL).times
        expect(client).not_to have_received(:sleep).with(0.5)
      end
    end

    it 'Azure status failed / ocr_failed はretryしない' do
      failed_response = faraday_response(status: 200, body: JSON.generate({ 'status' => 'failed' }))
      allow(Faraday).to receive(:get).and_return(failed_response)
      allow(client).to receive(:sleep)

      expect do
        client.send(:poll_result, operation_location)
      end.to raise_error(Ocr::OcrError, 'ocr_failed')

      aggregate_failures do
        expect(Faraday).to have_received(:get).once
        expect(client).not_to have_received(:sleep).with(0.5)
      end
    end
  end

  describe '#available?' do
    it 'call が成功すれば true を返す' do
      allow(client).to receive(:check_availability).and_return(true)

      expect(client.available?).to eq(true)
    end

    it 'OcrError の場合は false を返す' do
      allow(client).to receive(:check_availability).and_raise(Ocr::OcrError.new('ocr_api_error'))

      expect(client.available?).to eq(false)
    end

    it 'OcrTimeoutError の場合は false を返す' do
      allow(client).to receive(:check_availability).and_raise(Ocr::OcrTimeoutError.new('ocr_timeout'))

      expect(client.available?).to eq(false)
    end
  end

  describe '#handle_response_status!' do
    let(:response) { instance_double(Faraday::Response, status: status, headers: {}) }

    subject(:handle_status) { client.send(:handle_response_status!, response) }

    context '401 の場合' do
      let(:status) { 401 }

      it 'external_service_auth_error を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_auth_error')
      end
    end

    context '403 の場合' do
      let(:status) { 403 }

      it 'external_service_auth_error を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_auth_error')
      end
    end

    context '404 の場合' do
      let(:status) { 404 }

      it 'input_invalid を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'input_invalid')
      end
    end

    context '408 の場合' do
      let(:status) { 408 }

      it 'ocr_timeout を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')
      end
    end

    context '429 の場合' do
      let(:status) { 429 }

      it 'external_service_unavailable を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_unavailable')
      end
    end

    context '500 の場合' do
      let(:status) { 500 }

      it 'external_service_unavailable を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_unavailable')
      end
    end

    context '422 の場合' do
      let(:status) { 422 }

      it 'ocr_api_error を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'ocr_api_error')
      end
    end
  end

  describe '#request_body' do
    it 'download を持つオブジェクトなら download 結果を返す' do
      downloadable = instance_double('Downloadable')
      allow(downloadable).to receive(:download).and_return('downloaded-binary')

      request_client = described_class.new(image: downloadable, provider: provider)

      expect(request_client.send(:request_body)).to eq('downloaded-binary')
    end

    it 'read を持つオブジェクトなら read 結果を返す' do
      readable = StringIO.new('io-binary')
      request_client = described_class.new(image: readable, provider: provider)

      expect(request_client.send(:request_body)).to eq('io-binary')
    end

    it 'それ以外はそのまま返す' do
      raw = 'raw-binary'
      request_client = described_class.new(image: raw, provider: provider)

      expect(request_client.send(:request_body)).to eq('raw-binary')
    end
  end
end
