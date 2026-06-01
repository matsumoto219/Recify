require "faraday"
require "json"
require "time"

module Ocr
  class Client
    DEFAULT_TIMEOUT = 30
    # NOTE:
    # 現時点では単純な固定間隔 polling。
    # Azure 側の解析完了が遅い場合は、この間隔や回数が先にボトルネックになる。
    # 将来は backoff や provider ごとの最適値調整を検討する。
    DEFAULT_POLL_INTERVAL = 1.0
    # NOTE:
    # 受信JSONの行数上限ではなく、まずは polling 上限が実運用上のボトルネックになりやすい。
    # レスポンスが大きい場合や Azure 側が混雑している場合、ここが短すぎると ocr_timeout になる。
    # 現時点では保守的な初期値とし、実データを見ながら後で調整する。
    DEFAULT_MAX_POLL = 20
    DEFAULT_MAX_RETRIES = 2
    DEFAULT_BASE_RETRY_DELAY = 0.5
    DEFAULT_MAX_RETRY_DELAY = 10.0

    POLL_INTERVAL = DEFAULT_POLL_INTERVAL
    MAX_POLL = DEFAULT_MAX_POLL
    MAX_RETRIES = DEFAULT_MAX_RETRIES
    BASE_RETRY_DELAY = DEFAULT_BASE_RETRY_DELAY
    MAX_RETRY_DELAY = DEFAULT_MAX_RETRY_DELAY
    QUERY_FIELDS_FEATURE = "queryFields"
    QUERY_FIELDS = [ "PaymentMethod" ].freeze

    def initialize(image:, provider: "azure_document_intelligence")
      @image = image
      @provider = provider
    end

    def call
      Rails.logger.info("[OCR::Client] request start provider=#{provider}")

      op_location = submit_request
      result = poll_result(op_location)

      Rails.logger.info("[OCR::Client] request success provider=#{provider}")
      result
    rescue Faraday::TimeoutError
      Rails.logger.error("[OCR::Client] timeout")
      raise OcrTimeoutError, "ocr_timeout"
    rescue Faraday::ConnectionFailed => e
      Rails.logger.error("[OCR::Client] connection failed class=#{e.class} error_code=external_service_unavailable")
      raise OcrError, "external_service_unavailable"
    rescue OcrError, OcrTimeoutError
      raise
    rescue StandardError => e
      Rails.logger.error("[OCR::Client] request failed class=#{e.class} error_code=unexpected_error")
      raise OcrError, "unexpected_error"
    end

    # NOTE:
    # available? は親facadeの診断入口から使う疎通診断メソッド。
    # 通常のOCR処理前には毎回呼ばない。
    # UI表示や通常リクエストでは ExternalServices の状態storeを参照する。
    def available?
      check_availability
      true
    rescue OcrError, OcrTimeoutError
      false
    end

    private

    attr_reader :image, :provider

    def connection
      @connection ||= Faraday.new(url: endpoint) do |f|
        f.options.timeout = timeout
        f.adapter Faraday.default_adapter
      end
    end

    def submit_request
      # POST timeout は Azure 側で受理済みの可能性があるため retry しない。
      res = with_retries(operation: :submit_request, retry_timeouts: false) do
        connection.post do |req|
          req.url analyze_path
          req.headers["Ocp-Apim-Subscription-Key"] = api_key
          req.headers["Content-Type"] = "application/octet-stream"
          req.body = request_body
        end.tap do |response|
          handle_response_status!(response)
        end
      end

      op_location = res.headers["operation-location"] || res.headers["Operation-Location"]
      raise OcrError, "ocr_invalid_response" if op_location.blank?

      op_location
    end

    def poll_result(op_location)
      max_poll.times do
        sleep poll_interval

        res = with_retries(operation: :poll_result, retry_timeouts: true) do
          Faraday.get(op_location) do |req|
            req.headers["Ocp-Apim-Subscription-Key"] = api_key
          end.tap do |response|
            handle_response_status!(response)
          end
        end

        # NOTE:
        # Azure のレスポンス本文は一旦そのまま受け取り、後段 parser で必要部分だけ使う方針。
        # 現時点ではここで本文を切り詰めない。
        # 将来ボトルネックになる場合は、受信サイズそのものより parser / 保存方針 / polling を先に見直す。
        body = JSON.parse(res.body)
        status = body["status"]

        case status
        when "succeeded"
          return body
        when "failed"
          raise OcrError, "ocr_failed"
        else
          next
        end
      end

      raise OcrTimeoutError, "ocr_timeout"
    end

    def request_body
      return image.download if image.respond_to?(:download)

      if image.respond_to?(:read)
        image.rewind if image.respond_to?(:rewind)
        return image.read
      end

      image
    end

    def with_retries(operation:, retry_timeouts:)
      attempts = 0

      begin
        attempts += 1
        yield
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed, OcrError, OcrTimeoutError => e
        raise unless retryable_error?(e, retry_timeouts:)
        raise if attempts > max_retries

        retry_delay = retry_delay_for(attempts, e)
        Rails.logger.warn(
          "[OCR::Client] retry operation=#{operation} attempt=#{attempts} delay=#{retry_delay} error_code=#{error_code_for(e)} class=#{e.class}"
        )
        sleep(retry_delay)
        retry
      end
    end

    def retryable_error?(error, retry_timeouts:)
      case error
      when Faraday::TimeoutError
        retry_timeouts
      when Faraday::ConnectionFailed
        true
      when OcrTimeoutError
        error.message == "ocr_timeout"
      when OcrError
        error.message == "external_service_unavailable"
      else
        false
      end
    end

    def retry_delay_for(attempt, error = nil)
      retry_after = retry_after_for(error)
      return cap_retry_delay(retry_after) if retry_after

      cap_retry_delay(exponential_retry_delay(attempt) + retry_jitter_delay)
    end

    def exponential_retry_delay(attempt)
      base_retry_delay * (2**(attempt - 1))
    end

    def retry_jitter_delay
      rand * base_retry_delay
    end

    def retry_after_for(error)
      return unless error.respond_to?(:retry_after)

      error.retry_after
    end

    def cap_retry_delay(delay)
      [ delay.to_f, max_retry_delay ].min
    end

    def error_code_for(error)
      case error
      when Faraday::TimeoutError, OcrTimeoutError
        "ocr_timeout"
      when Faraday::ConnectionFailed
        "external_service_unavailable"
      when OcrError
        error.message
      else
        "unexpected_error"
      end
    end

    # provider依存の疎通確認実装。通常処理フローからは直接使わない。
    def check_availability
      res = connection.get do |req|
        req.url analyze_path
        req.headers["Ocp-Apim-Subscription-Key"] = api_key
      end

      handle_response_status!(res)
    rescue Faraday::TimeoutError
      raise OcrTimeoutError, "ocr_timeout"
    rescue Faraday::ConnectionFailed
      raise OcrError, "external_service_unavailable"
    end

    # NOTE:
    # 外部サービス状態管理では、このメソッドで寄せた error_code を利用して
    # ok / degraded / down の状態遷移を判定する想定。
    # input_invalid や ocr_unreadable のような入力起因エラーは
    # 外部サービス障害カウントに含めない。
    def handle_response_status!(res)
      return if res.status.between?(200, 299)

      error_code = case res.status
      when 401
        "external_service_auth_error"
      when 403
        "external_service_auth_error"
      when 404
        "input_invalid"
      when 408
        "ocr_timeout"
      when 429
        "external_service_unavailable"
      when 500..599
        "external_service_unavailable"
      else
        "ocr_api_error"
      end

      Rails.logger.error(
        "[OCR::Client] bad response status=#{res.status} error_code=#{error_code}"
      )

      retry_after = retryable_response_status?(res.status) ? retry_after_from_headers(res.headers) : nil
      error_class = error_code == "ocr_timeout" ? OcrTimeoutError : OcrError
      raise error_class.new(error_code, retry_after:)
    end

    def retryable_response_status?(status)
      status == 408 || status == 429 || status.between?(500, 599)
    end

    def retry_after_from_headers(headers)
      value = retry_after_header_value(headers)
      return if value.blank?

      parse_retry_after(value)
    end

    def retry_after_header_value(headers)
      return unless headers

      header = headers.find { |key, _value| key.to_s.casecmp("retry-after").zero? }
      header&.last
    end

    def parse_retry_after(value)
      raw_value = value.to_s.strip
      return if raw_value.blank?

      if raw_value.match?(/\A\d+(?:\.\d+)?\z/)
        return cap_retry_delay(raw_value.to_f)
      end

      delay = Time.httpdate(raw_value) - Time.current
      return if delay.negative?

      cap_retry_delay(delay)
    rescue ArgumentError
      nil
    end

    def endpoint
      ENV.fetch("AZURE_OCR_ENDPOINT")
    end

    def analyze_path
      query = {
        "api-version" => "2024-11-30",
        "features" => QUERY_FIELDS_FEATURE,
        "queryFields" => QUERY_FIELDS.join(",")
      }.to_query

      "/documentintelligence/documentModels/prebuilt-receipt:analyze?#{query}"
    end

    def api_key
      ENV.fetch("AZURE_OCR_API_KEY")
    end

    def timeout
      ENV.fetch("AZURE_OCR_TIMEOUT", DEFAULT_TIMEOUT).to_i
    end

    def max_poll
      ENV.fetch("AZURE_OCR_MAX_POLL", DEFAULT_MAX_POLL).to_i
    end

    def poll_interval
      ENV.fetch("AZURE_OCR_POLL_INTERVAL", DEFAULT_POLL_INTERVAL).to_f
    end

    def max_retries
      ENV.fetch("AZURE_OCR_MAX_RETRIES", DEFAULT_MAX_RETRIES).to_i
    end

    def base_retry_delay
      ENV.fetch("AZURE_OCR_BASE_RETRY_DELAY", DEFAULT_BASE_RETRY_DELAY).to_f
    end

    def max_retry_delay
      ENV.fetch("AZURE_OCR_MAX_RETRY_DELAY", DEFAULT_MAX_RETRY_DELAY).to_f
    end
  end

  class OcrError < StandardError
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  class OcrTimeoutError < StandardError
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
end
