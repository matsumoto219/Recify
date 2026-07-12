require 'rails_helper'

RSpec.describe Ocr::Client do
  let(:image_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:image) { Rack::Test::UploadedFile.new(image_path, 'image/jpeg') }
  let(:provider) { 'azure_document_intelligence' }
  let(:before_provider_call) { nil }
  let(:runtime_config_overrides) { {} }
  let(:runtime_config) do
    ExternalServices.runtime_config_snapshot.ocr.with(**runtime_config_overrides)
  end
  let(:client) do
    described_class.new(
      image: image,
      provider: provider,
      runtime_config: runtime_config,
      before_provider_call: before_provider_call
    )
  end
  let(:configured_env) do
    {
      'AZURE_OCR_ENDPOINT' => 'https://example.cognitiveservices.azure.com',
      'AZURE_OCR_API_KEY' => 'test-key'
    }
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
    Struct.new(:headers, :body, :options) do
      def url(value)
        @url = value
      end
    end.new({}, nil, Faraday::RequestOptions.new)
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

  def client_with_runtime_config(**overrides)
    described_class.new(
      image: image,
      provider: provider,
      runtime_config: ExternalServices.runtime_config_snapshot.ocr.with(**overrides),
      before_provider_call: before_provider_call
    )
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
    with_env(configured_env) do
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
    around do |example|
      with_env(
        'AZURE_OCR_ENDPOINT' => 'https://example.cognitiveservices.azure.com',
        'AZURE_OCR_API_KEY' => 'test-key'
      ) do
        example.run
      end
    end

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

    it 'endpoint未設定ではprovider callbackを呼ばずsubmitしない' do
      callback = instance_double(Proc)
      callback_client = described_class.new(image: image, provider: provider, before_provider_call: callback)
      connection = stub_connection_post(callback_client, accepted_response)
      allow(callback).to receive(:call)

      with_env('AZURE_OCR_ENDPOINT' => nil, 'AZURE_OCR_API_KEY' => 'test-key') do
        expect do
          callback_client.send(:submit_request)
        end.to raise_error(Ocr::OcrError, 'external_service_unavailable')
      end

      aggregate_failures do
        expect(callback).not_to have_received(:call)
        expect(connection).not_to have_received(:post)
      end
    end

    it 'api key未設定ではprovider callbackを呼ばずsubmitしない' do
      callback = instance_double(Proc)
      callback_client = described_class.new(image: image, provider: provider, before_provider_call: callback)
      connection = stub_connection_post(callback_client, accepted_response)
      allow(callback).to receive(:call)

      with_env(
        'AZURE_OCR_ENDPOINT' => 'https://example.cognitiveservices.azure.com',
        'AZURE_OCR_API_KEY' => nil
      ) do
        expect do
          callback_client.send(:submit_request)
        end.to raise_error(Ocr::OcrError, 'external_service_auth_error')
      end

      aggregate_failures do
        expect(callback).not_to have_received(:call)
        expect(connection).not_to have_received(:post)
      end
    end

    it '画像blob取得失敗ではprovider callbackを呼ばずsubmitしない' do
      corrupt_image = instance_double('AttachedImage')
      callback = instance_double(Proc)
      callback_client = described_class.new(image: corrupt_image, provider: provider, before_provider_call: callback)
      connection = stub_connection_post(callback_client, accepted_response)
      allow(corrupt_image).to receive(:download).and_raise(ActiveStorage::FileNotFoundError)
      allow(callback).to receive(:call)

      expect do
        callback_client.send(:submit_request)
      end.to raise_error(ActiveStorage::FileNotFoundError)

      aggregate_failures do
        expect(callback).not_to have_received(:call)
        expect(connection).not_to have_received(:post)
      end
    end

    it 'Azure submitへ到達する直前にprovider callbackを呼ぶ' do
      callback = instance_double(Proc)
      callback_client = described_class.new(image: image, provider: provider, before_provider_call: callback)
      connection = stub_connection_post(
        callback_client,
        faraday_response(
          status: 403,
          body: {
            error: {
              code: 'QuotaExceeded',
              message: 'F0 quota exceeded'
            }
          }.to_json
        )
      )
      allow(callback).to receive(:call)

      expect do
        callback_client.send(:submit_request)
      end.to raise_error(Ocr::OcrError, 'external_service_quota_exceeded')

      aggregate_failures do
        expect(callback).to have_received(:call).once
        expect(connection).to have_received(:post).once
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

    {
      'plaintext HTTP' => 'http://example.cognitiveservices.azure.com/operations/123',
      'localhost' => 'https://127.0.0.1/operations/123',
      'metadata endpoint' => 'https://169.254.169.254/latest/meta-data',
      'host suffix' => 'https://example.cognitiveservices.azure.com.attacker.example/operations/123',
      'userinfo' => 'https://attacker.example@example.cognitiveservices.azure.com/operations/123',
      'scheme relative URL' => '//example.cognitiveservices.azure.com/operations/123',
      'different port' => 'https://example.cognitiveservices.azure.com:444/operations/123',
      'fragment' => 'https://example.cognitiveservices.azure.com/operations/123#secret'
    }.each do |description, untrusted_location|
      it "#{description}のoperation-locationを拒否する" do
        response = faraday_response(status: 202, headers: { 'operation-location' => untrusted_location })
        connection = stub_connection_post(client, response)

        expect do
          client.send(:submit_request)
        end.to raise_error(Ocr::OcrError, 'ocr_invalid_response')

        expect(connection).to have_received(:post).once
      end
    end
  end

  describe 'runtime config' do
    it '画像downloadを含むOCR処理全体をmax elapsedで中断する' do
      slow_image = instance_double('SlowDownloadable')
      slow_client = described_class.new(
        image: slow_image,
        provider: provider,
        runtime_config: runtime_config.with(max_elapsed_seconds: 0.01)
      )
      connection = instance_double(Faraday::Connection)
      allow(slow_image).to receive(:download) do
        sleep 0.05
        'image-binary'
      end
      allow(slow_client).to receive(:connection).and_return(connection)
      allow(connection).to receive(:post).and_raise('provider call must not start')

      expect do
        slow_client.call
      end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')

      expect(connection).not_to have_received(:post)
    end

    it 'request timeoutをsubmit connectionへ設定する' do
      connection = client.send(:connection)

      aggregate_failures do
        expect(connection.options.timeout).to eq(30)
        expect(connection.options.open_timeout).to eq(30)
      end
    end

    it 'request timeoutをpolling GETへも明示設定する' do
      poll_request = request_double
      succeeded_poll_response = faraday_response(status: 200, body: JSON.generate(succeeded_response))
      allow(Faraday).to receive(:get) do |_url, &block|
        block.call(poll_request)
        succeeded_poll_response
      end
      allow(client).to receive(:sleep)

      client.send(:poll_result, operation_location)

      aggregate_failures do
        expect(poll_request.options.timeout).to eq(30.0)
        expect(poll_request.options.open_timeout).to eq(30.0)
      end
    end

    it '残り時間がrequest timeoutより短い場合はpolling timeoutを残り時間でcapする' do
      poll_request = request_double
      succeeded_poll_response = faraday_response(status: 200, body: JSON.generate(succeeded_response))
      allow(Faraday).to receive(:get) do |_url, &block|
        block.call(poll_request)
        succeeded_poll_response
      end
      allow(client).to receive(:sleep)
      allow(client).to receive(:remaining_elapsed_seconds).and_return(5.0)

      client.send(:poll_result, operation_location)

      aggregate_failures do
        expect(poll_request.options.timeout).to eq(5.0)
        expect(poll_request.options.open_timeout).to eq(5.0)
      end
    end

    it 'max elapsedで次のpolling requestを開始せずocr_timeoutへ倒す' do
      allow(client).to receive(:remaining_elapsed_seconds).and_return(0.5)
      expect(Faraday).not_to receive(:get)

      expect do
        client.send(:poll_result, operation_location)
      end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')
    end

    it 'max poll attemptsとbase intervalをruntime configから読む' do
      configured_client = client_with_runtime_config(max_poll_attempts: 2, poll_interval_seconds: 0.25)
      running_response = faraday_response(status: 200, body: JSON.generate({ 'status' => 'running' }))
      allow(Faraday).to receive(:get).and_return(running_response)
      allow(configured_client).to receive(:sleep)

      expect do
        configured_client.send(:poll_result, operation_location)
      end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout')

      aggregate_failures do
        expect(Faraday).to have_received(:get).twice
        expect(configured_client).to have_received(:sleep).with(0.25).once
        expect(configured_client).to have_received(:sleep).with(0.375).once
      end
    end

    it 'polling delayはintervalにbackoff factorをかけてmax poll intervalでcapする' do
      expect((0..5).map { |index| client.send(:poll_delay_for, index) }).to eq(
        [
          1.0,
          1.5,
          2.25,
          3.0,
          3.0,
          3.0
        ]
      )
    end

    it 'polling delayはRetry-Afterを優先しmax poll intervalでcapする' do
      aggregate_failures do
        expect(client.send(:poll_delay_for, 2, retry_after: 2.5)).to eq(2.5)
        expect(client.send(:poll_delay_for, 2, retry_after: 30.0)).to eq(3.0)
      end
    end

    it 'poll backoffとmax intervalをruntime configから読む' do
      configured_client = client_with_runtime_config(
        poll_interval_seconds: 0.5,
        poll_backoff_factor: 2.0,
        max_poll_interval_seconds: 2.5
      )

      aggregate_failures do
        expect((0..4).map { |index| configured_client.send(:poll_delay_for, index) }).to eq([ 0.5, 1.0, 2.0, 2.5, 2.5 ])
        expect(configured_client.send(:poll_delay_for, 0, retry_after: 9.0)).to eq(2.5)
      end
    end

    it 'max retriesをruntime configから読む' do
      configured_client = client_with_runtime_config(max_retries: 0)
      connection = stub_connection_post(configured_client, faraday_response(status: 429))
      allow(configured_client).to receive(:sleep)

      expect do
        configured_client.send(:submit_request)
      end.to raise_error(Ocr::OcrError, 'external_service_rate_limited')

      aggregate_failures do
        expect(connection).to have_received(:post).once
        expect(configured_client).not_to have_received(:sleep)
      end
    end

    it 'retry delayをruntime configから読む' do
      configured_client = client_with_runtime_config(base_retry_delay_seconds: 2.0, max_retry_delay_seconds: 3.0)
      allow(configured_client).to receive(:retry_jitter_delay).and_return(0.25)

      aggregate_failures do
        expect(configured_client.send(:retry_delay_for, 1)).to eq(2.25)
        expect(configured_client.send(:retry_delay_for, 3)).to eq(3.0)
      end
    end

    it '廃止した数値ENVを参照しない' do
      with_env(
        'AZURE_OCR_TIMEOUT' => '99',
        'AZURE_OCR_MAX_POLL' => '99',
        'AZURE_OCR_MAX_RETRIES' => '0'
      ) do
        expect(client.send(:timeout)).to eq(30)
        expect(client.send(:max_poll)).to eq(20)
        expect(client.send(:max_retries)).to eq(2)
      end
    end
  end

  describe '#poll_result' do
    let(:succeeded_poll_response) do
      faraday_response(status: 200, body: JSON.generate(succeeded_response))
    end

    it 'polling入口でも異なるoriginを拒否しAPI keyを送信しない' do
      expect(Faraday).not_to receive(:get)
      allow(client).to receive(:sleep)

      expect do
        client.send(:poll_result, 'https://attacker.example/operations/123')
      end.to raise_error(Ocr::OcrError, 'ocr_invalid_response')

      expect(client).not_to have_received(:sleep)
    end

    it '設定endpointと同一originのHTTPS operation-locationだけを許可する' do
      poll_request = request_double
      allow(Faraday).to receive(:get) do |url, &block|
        block.call(poll_request)
        succeeded_poll_response
      end
      allow(client).to receive(:sleep)

      result = client.send(:poll_result, "#{operation_location}?api-version=2024-11-30")

      aggregate_failures do
        expect(result.except(described_class::POLLING_METRICS_KEY)).to eq(succeeded_response)
        expect(Faraday).to have_received(:get).once
        expect(poll_request.headers['Ocp-Apim-Subscription-Key']).to eq('test-key')
      end
    end

    it '202 AcceptedのRetry-Afterを初回poll sleepに使う' do
      retry_after_accepted_response = faraday_response(
        status: 202,
        headers: { 'operation-location' => operation_location, 'Retry-After' => '2' }
      )
      connection = stub_connection_post(client, retry_after_accepted_response)
      allow(Faraday).to receive(:get).and_return(succeeded_poll_response)
      allow(client).to receive(:sleep)

      result = client.call

      aggregate_failures do
        expect(result.except(described_class::POLLING_METRICS_KEY)).to eq(succeeded_response)
        expect(result[described_class::POLLING_METRICS_KEY]).to include(
          'total_poll_sleep_ms' => 2000,
          'max_poll_interval' => runtime_config.max_poll_interval_seconds,
          'poll_backoff_factor' => runtime_config.poll_backoff_factor,
          'retry_after_used' => true
        )
        expect(connection).to have_received(:post).once
        expect(Faraday).to have_received(:get).once
        expect(client).to have_received(:sleep).with(2.0).once
        expect(client).not_to have_received(:sleep).with(1.0)
      end
    end

    it 'succeededのraw response bodyをcallbackへ渡し、parser向け戻り値にはpolling metricsだけを追加する' do
      raw_body = JSON.generate(succeeded_response)
      callback = spy('success response callback')
      callback_client = described_class.new(
        image: image,
        provider: provider,
        before_provider_call: nil,
        after_provider_success_response: callback
      )
      allow(Faraday).to receive(:get).and_return(faraday_response(status: 200, body: raw_body))
      allow(callback_client).to receive(:sleep)

      result = callback_client.send(:poll_result, operation_location)

      aggregate_failures do
        expect(callback).to have_received(:call).with(
          raw_body,
          response: succeeded_response,
          provider: provider
        )
        expect(result.except(described_class::POLLING_METRICS_KEY)).to eq(succeeded_response)
        expect(result[described_class::POLLING_METRICS_KEY]).to include('final_status' => 'succeeded')
      end
    end

    it 'running中レスポンスのRetry-Afterを次回poll sleepに使う' do
      outcomes = [
        faraday_response(status: 200, headers: { 'Retry-After' => '2.5' }, body: JSON.generate({ 'status' => 'running' })),
        succeeded_poll_response
      ]
      allow(Faraday).to receive(:get) do
        outcomes.shift
      end
      allow(client).to receive(:sleep)

      result = client.send(:poll_result, operation_location)

      aggregate_failures do
        expect(result.except(described_class::POLLING_METRICS_KEY)).to eq(succeeded_response)
        expect(result[described_class::POLLING_METRICS_KEY]).to include(
          'total_poll_sleep_ms' => 3500,
          'retry_after_used' => true
        )
        expect(Faraday).to have_received(:get).twice
        expect(client).to have_received(:sleep).with(1.0).once
        expect(client).to have_received(:sleep).with(2.5).once
      end
    end

    it 'Retry-Afterがない場合はcapped backoffでpollingする' do
      outcomes = [
        faraday_response(status: 200, body: JSON.generate({ 'status' => 'running' })),
        faraday_response(status: 200, body: JSON.generate({ 'status' => 'running' })),
        faraday_response(status: 200, body: JSON.generate({ 'status' => 'running' })),
        succeeded_poll_response
      ]
      allow(Faraday).to receive(:get) do
        outcomes.shift
      end
      allow(client).to receive(:sleep)

      result = client.send(:poll_result, operation_location)

      aggregate_failures do
        expect(result.except(described_class::POLLING_METRICS_KEY)).to eq(succeeded_response)
        expect(result[described_class::POLLING_METRICS_KEY]).to include(
          'total_poll_sleep_ms' => 7750,
          'max_poll_interval' => runtime_config.max_poll_interval_seconds,
          'poll_backoff_factor' => runtime_config.poll_backoff_factor,
          'retry_after_used' => false
        )
        expect(Faraday).to have_received(:get).exactly(4).times
        expect(client).to have_received(:sleep).with(1.0).once
        expect(client).to have_received(:sleep).with(1.5).once
        expect(client).to have_received(:sleep).with(2.25).once
        expect(client).to have_received(:sleep).with(3.0).once
      end
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
        expect(result.except(described_class::POLLING_METRICS_KEY)).to eq(succeeded_response)
        expect(result[described_class::POLLING_METRICS_KEY]).to include(
          'poll_count' => 2,
          'final_status' => 'succeeded',
          'max_poll_count' => runtime_config.max_poll_attempts,
          'poll_interval' => runtime_config.poll_interval_seconds,
          'reached_max_poll' => false,
          'retry_after_used' => false,
          'retry_count' => 1
        )
        expect(result[described_class::POLLING_METRICS_KEY]['elapsed_ms']).to be_a(Integer)
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
        expect(result.except(described_class::POLLING_METRICS_KEY)).to eq(succeeded_response)
        expect(result[described_class::POLLING_METRICS_KEY]).to include(
          'poll_count' => 2,
          'final_status' => 'succeeded',
          'retry_after_used' => false,
          'retry_count' => 1
        )
        expect(connection).to have_received(:post).once
        expect(Faraday).to have_received(:get).twice
        expect(client).to have_received(:sleep).with(0.5).once
      end
    end

    it 'polling GET のRetry-After利用をmetricsに残す' do
      outcomes = [
        faraday_response(status: 500, headers: { 'Retry-After' => '3' }),
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
        expect(result[described_class::POLLING_METRICS_KEY]).to include(
          'poll_count' => 2,
          'final_status' => 'succeeded',
          'retry_after_used' => true,
          'retry_count' => 1
        )
        expect(client).to have_received(:sleep).with(3.0).once
      end
    end

    it 'MAX_POLL超過の ocr_timeout はretryしない' do
      running_response = faraday_response(status: 200, body: JSON.generate({ 'status' => 'running' }))
      allow(Faraday).to receive(:get).and_return(running_response)
      allow(client).to receive(:sleep)

      expect do
        client.send(:poll_result, operation_location)
      end.to raise_error(Ocr::OcrTimeoutError, 'ocr_timeout') { |error|
        expect(error.polling_metrics).to include(
          'poll_count' => runtime_config.max_poll_attempts,
          'final_status' => 'running',
          'max_poll_count' => runtime_config.max_poll_attempts,
          'poll_interval' => runtime_config.poll_interval_seconds,
          'reached_max_poll' => true,
          'retry_after_used' => false,
          'retry_count' => 0
        )
      }

      aggregate_failures do
        expect(Faraday).to have_received(:get).exactly(runtime_config.max_poll_attempts).times
        expect(client).not_to have_received(:sleep).with(0.5)
      end
    end

    it 'Azure status failed / ocr_failed はretryしない' do
      failed_response = faraday_response(status: 200, body: JSON.generate({ 'status' => 'failed' }))
      allow(Faraday).to receive(:get).and_return(failed_response)
      allow(client).to receive(:sleep)

      expect do
        client.send(:poll_result, operation_location)
      end.to raise_error(Ocr::OcrError, 'ocr_failed') { |error|
        expect(error.polling_metrics).to include(
          'poll_count' => 1,
          'final_status' => 'failed',
          'reached_max_poll' => false,
          'retry_after_used' => false,
          'retry_count' => 0
        )
      }

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

    it 'analyze endpointへGETせず静的な設定確認だけでtrueを返す' do
      with_env(
        'AZURE_OCR_ENDPOINT' => 'https://example.cognitiveservices.azure.com',
        'AZURE_OCR_API_KEY' => 'test-key'
      ) do
        expect(Faraday).not_to receive(:get)

        expect(client.available?).to eq(true)
      end
    end

    it 'endpoint未設定ならprovider detail付きでfalseを返す' do
      with_env('AZURE_OCR_ENDPOINT' => nil, 'AZURE_OCR_API_KEY' => 'test-key') do
        expect(client.available?).to eq(false)
      end
    end

    it 'api key未設定ならprovider detail付きのauth errorを投げる' do
      with_env(
        'AZURE_OCR_ENDPOINT' => 'https://example.cognitiveservices.azure.com',
        'AZURE_OCR_API_KEY' => nil
      ) do
        expect { client.send(:check_availability) }
          .to raise_error(Ocr::OcrError, 'external_service_auth_error') { |error|
            expect(error.provider_error_detail).to include(
              service: 'ocr',
              provider: provider,
              phase: 'availability',
              provider_error_code: 'api_key_missing',
              auth_error: true
            )
          }
      end
    end

    it 'endpoint形式が不正ならexternal_service_unavailableを投げる' do
      with_env('AZURE_OCR_ENDPOINT' => 'not a url', 'AZURE_OCR_API_KEY' => 'test-key') do
        expect { client.send(:check_availability) }
          .to raise_error(Ocr::OcrError, 'external_service_unavailable') { |error|
            expect(error.provider_error_detail).to include(
              service: 'ocr',
              provider: provider,
              phase: 'availability',
              provider_error_code: 'endpoint_invalid'
            )
          }
      end
    end

    it 'plaintext HTTP endpointを拒否する' do
      with_env('AZURE_OCR_ENDPOINT' => 'http://example.cognitiveservices.azure.com', 'AZURE_OCR_API_KEY' => 'test-key') do
        expect { client.send(:check_availability) }
          .to raise_error(Ocr::OcrError, 'external_service_unavailable') { |error|
            expect(error.provider_error_detail).to include(provider_error_code: 'endpoint_invalid')
          }
      end
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
    let(:headers) { {} }
    let(:body) { '{}' }
    let(:response) { instance_double(Faraday::Response, status: status, headers: headers, body: body) }

    subject(:handle_status) { client.send(:handle_response_status!, response, phase: 'submit') }

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

      context 'Azure quota exceeded bodyの場合' do
        let(:headers) do
          {
            'retry-after' => '1748518',
            'apim-request-id' => 'req-1',
            'x-ms-region' => 'Japan East'
          }
        end
        let(:body) do
          {
            error: {
              code: '403',
              message: 'Out of call volume quota for FormRecognizer F0 pricing tier. Please retry after 21 days.'
            }
          }.to_json
        end

        it 'external_service_quota_exceeded に分類しsafe metadataを保持する' do
          expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_quota_exceeded') { |error|
            expect(error.provider_error_detail).to include(
              service: 'ocr',
              provider: provider,
              phase: 'submit',
              http_status: 403,
              provider_error_code: '403',
              request_id: 'req-1',
              region: 'Japan East',
              retry_after: 1_748_518.0,
              quota_exceeded: true
            )
            expect(error.provider_error_detail[:provider_message_safe]).to include('Out of call volume quota')
          }
        end
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

      it 'external_service_rate_limited を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'external_service_rate_limited')
      end
    end

    context '415 の場合' do
      let(:status) { 415 }

      it 'input_invalid を投げる' do
        expect { handle_status }.to raise_error(Ocr::OcrError, 'input_invalid')
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
