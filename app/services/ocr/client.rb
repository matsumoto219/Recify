require "faraday"
require "json"
require "time"

module Ocr
  class Client
    DEFAULT_TIMEOUT = 30
    # NOTE:
    # pollingはRetry-Afterを優先し、未指定時はbase intervalから緩やかにcapped backoffする。
    # 408/429/5xxやpolling GET timeoutのretryでは、別系統のRetry-After / backoff / jitterを利用する。
    # request timeout / polling / retry値は AZURE_OCR_* ENV で運用調整できる。
    DEFAULT_POLL_INTERVAL = 1.0
    # NOTE:
    # 受信JSONの行数上限ではなく、まずは polling 上限が実運用上のボトルネックになりやすい。
    # レスポンスが大きい場合や Azure 側が混雑している場合、ここが短すぎると ocr_timeout になる。
    # 現時点ではbase interval 1秒/max 20回を維持し、staging / production のOCR latencyとpolling metricsを見て
    # poll_backoff_factor / max_poll_interval を調整する。
    DEFAULT_MAX_POLL = 20
    DEFAULT_MAX_RETRIES = 2
    DEFAULT_POLL_BACKOFF_FACTOR = 1.5
    DEFAULT_MAX_POLL_INTERVAL = 3.0
    DEFAULT_BASE_RETRY_DELAY = 0.5
    DEFAULT_MAX_RETRY_DELAY = 10.0

    POLL_INTERVAL = DEFAULT_POLL_INTERVAL
    MAX_POLL = DEFAULT_MAX_POLL
    MAX_RETRIES = DEFAULT_MAX_RETRIES
    POLL_BACKOFF_FACTOR = DEFAULT_POLL_BACKOFF_FACTOR
    MAX_POLL_INTERVAL = DEFAULT_MAX_POLL_INTERVAL
    BASE_RETRY_DELAY = DEFAULT_BASE_RETRY_DELAY
    MAX_RETRY_DELAY = DEFAULT_MAX_RETRY_DELAY
    POLLING_METRICS_KEY = "recify_polling_metrics".freeze
    QUERY_FIELDS_FEATURE = "queryFields"
    QUERY_FIELDS = [ "PaymentMethods" ].freeze

    def initialize(image:, provider: "azure_document_intelligence")
      @image = image
      @provider = provider
    end

    def call
      reset_polling_metrics!
      Rails.logger.info("[OCR::Client] request start provider=#{provider}")

      op_location = submit_request
      result = poll_result(op_location)

      Rails.logger.info("[OCR::Client] request success provider=#{provider}")
      result
    rescue Faraday::TimeoutError
      Rails.logger.error("[OCR::Client] timeout")
      raise OcrTimeoutError.new("ocr_timeout", polling_metrics: polling_metrics(final_status: "timeout"))
    rescue Faraday::ConnectionFailed => e
      Rails.logger.error("[OCR::Client] connection failed class=#{e.class} error_code=external_service_unavailable")
      raise OcrError.new("external_service_unavailable", polling_metrics: polling_metrics(final_status: "external_service_unavailable"))
    rescue OcrError, OcrTimeoutError => e
      raise enrich_error_with_polling_metrics(e)
    rescue StandardError => e
      Rails.logger.error("[OCR::Client] request failed class=#{e.class} error_code=unexpected_error")
      raise OcrError.new("unexpected_error", polling_metrics: polling_metrics(final_status: "unexpected_error"))
    end

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
          handle_response_status!(response, phase: "submit")
        end
      end

      op_location = res.headers["operation-location"] || res.headers["Operation-Location"]
      raise OcrError, "ocr_invalid_response" if op_location.blank?

      @next_poll_retry_after = retry_after_from_headers(res.headers)
      op_location
    end

    def poll_result(op_location)
      ensure_polling_metrics!
      @polling_started_at ||= monotonic_now
      @last_poll_status = nil
      next_poll_retry_after = @next_poll_retry_after
      @next_poll_retry_after = nil

      max_poll.times do |index|
        poll_delay = poll_delay_for(index, retry_after: next_poll_retry_after)
        track_poll_sleep_metrics!(poll_delay, retry_after: next_poll_retry_after)
        sleep poll_delay
        next_poll_retry_after = nil

        res = with_retries(operation: :poll_result, retry_timeouts: true) do
          @poll_count += 1
          Faraday.get(op_location) do |req|
            req.headers["Ocp-Apim-Subscription-Key"] = api_key
          end.tap do |response|
            handle_response_status!(response, phase: "poll")
          end
        end
        next_poll_retry_after = retry_after_from_headers(res.headers)

        # NOTE:
        # Azure のレスポンス本文は一旦そのまま受け取り、後段 parser で必要部分だけ使う方針。
        # 現時点ではここで本文を切り詰めない。
        # 将来ボトルネックになる場合は、受信サイズそのものより parser / 保存方針 / polling を先に見直す。
        body = JSON.parse(res.body)
        status = body["status"]
        @last_poll_status = status

        case status
        when "succeeded"
          return body.merge(POLLING_METRICS_KEY => polling_metrics(final_status: status))
        when "failed"
          raise OcrError.new("ocr_failed", polling_metrics: polling_metrics(final_status: status))
        else
          next
        end
      end

      @reached_max_poll = true
      raise OcrTimeoutError.new(
        "ocr_timeout",
        polling_metrics: polling_metrics(final_status: @last_poll_status || "timeout", reached_max_poll: true)
      )
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

        track_retry_metrics!(e)
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
        %w[external_service_unavailable external_service_rate_limited].include?(error.message)
      else
        false
      end
    end

    def retry_delay_for(attempt, error = nil)
      retry_after = retry_after_for(error)
      return cap_retry_delay(retry_after) if retry_after

      cap_retry_delay(exponential_retry_delay(attempt) + retry_jitter_delay)
    end

    def poll_delay_for(index, retry_after: nil)
      return cap_poll_delay(retry_after) unless retry_after.nil?

      cap_poll_delay(poll_interval * (poll_backoff_factor**index.to_i))
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

    def reset_polling_metrics!
      @poll_count = 0
      @retry_count = 0
      @total_poll_sleep_ms = 0
      @retry_after_used = false
      @reached_max_poll = false
      @last_poll_status = nil
      @polling_started_at = nil
      @next_poll_retry_after = nil
    end

    def ensure_polling_metrics!
      reset_polling_metrics! unless defined?(@poll_count)
    end

    def track_retry_metrics!(error)
      ensure_polling_metrics!
      @retry_count += 1
      @retry_after_used = true if retry_after_for(error).present?
    end

    def track_poll_sleep_metrics!(delay, retry_after:)
      ensure_polling_metrics!
      @total_poll_sleep_ms += (delay.to_f * 1000).round
      @retry_after_used = true unless retry_after.nil?
    end

    def polling_metrics(final_status: nil, reached_max_poll: false)
      ensure_polling_metrics!

      {
        "elapsed_ms" => polling_elapsed_ms,
        "poll_count" => @poll_count,
        "final_status" => final_status,
        "max_poll_count" => max_poll,
        "poll_interval" => poll_interval,
        "total_poll_sleep_ms" => @total_poll_sleep_ms,
        "max_poll_interval" => max_poll_interval,
        "poll_backoff_factor" => poll_backoff_factor,
        "reached_max_poll" => reached_max_poll || @reached_max_poll == true,
        "retry_after_used" => @retry_after_used == true,
        "retry_count" => @retry_count
      }.compact
    end

    def polling_elapsed_ms
      return if @polling_started_at.blank?

      ((monotonic_now - @polling_started_at) * 1000).round
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def enrich_error_with_polling_metrics(error)
      return error if error.respond_to?(:polling_metrics) && error.polling_metrics.present?

      enriched = error.class.new(
        error.message,
        retry_after: error.respond_to?(:retry_after) ? error.retry_after : nil,
        polling_metrics: polling_metrics(final_status: error_code_for(error)),
        provider_error_detail: error.respond_to?(:provider_error_detail) ? error.provider_error_detail : nil
      )
      enriched.set_backtrace(error.backtrace)
      enriched
    end

    def cap_retry_delay(delay)
      [ delay.to_f, max_retry_delay ].min
    end

    def cap_poll_delay(delay)
      [ [ delay.to_f, 0.0 ].max, max_poll_interval ].min
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

      handle_response_status!(res, phase: "availability")
    rescue Faraday::TimeoutError
      raise OcrTimeoutError, "ocr_timeout"
    rescue Faraday::ConnectionFailed
      raise OcrError, "external_service_unavailable"
    end

    # 外部サービス状態管理では、このメソッドで寄せた error_code を利用して
    # ok / degraded / down の状態遷移を判定する想定。
    # input_invalid や ocr_unreadable のような入力起因エラーは
    # 外部サービス障害カウントに含めない。
    def handle_response_status!(res, phase:)
      return if res.status.between?(200, 299)

      error_detail = provider_error_detail_for(res, phase:)
      error_code = case res.status
      when 401
        "external_service_auth_error"
      when 403
        error_detail[:quota_exceeded] ? "external_service_quota_exceeded" : "external_service_auth_error"
      when 404
        "input_invalid"
      when 408
        "ocr_timeout"
      when 415
        "input_invalid"
      when 429
        "external_service_rate_limited"
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
      raise error_class.new(error_code, retry_after:, provider_error_detail: error_detail)
    end

    def retryable_response_status?(status)
      status == 408 || status == 429 || status.between?(500, 599)
    end

    def provider_error_detail_for(response, phase:)
      ExternalServices.error_detail(
        service: :ocr,
        provider: provider,
        phase: phase,
        http_status: response.status,
        body: response.body,
        headers: response.headers,
        retry_after: retry_after_from_headers(response.headers),
        poll_count: @poll_count
      )
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
        return raw_value.to_f
      end

      delay = Time.httpdate(raw_value) - Time.current
      return if delay.negative?

      delay
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

    def poll_backoff_factor
      ENV.fetch("AZURE_OCR_POLL_BACKOFF_FACTOR", DEFAULT_POLL_BACKOFF_FACTOR).to_f
    end

    def max_poll_interval
      ENV.fetch("AZURE_OCR_MAX_POLL_INTERVAL", DEFAULT_MAX_POLL_INTERVAL).to_f
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
    attr_reader :retry_after, :polling_metrics, :provider_error_detail

    def initialize(message = nil, retry_after: nil, polling_metrics: nil, provider_error_detail: nil)
      super(message)
      @retry_after = retry_after
      @polling_metrics = polling_metrics || {}
      @provider_error_detail = provider_error_detail || {}
    end
  end

  class OcrTimeoutError < StandardError
    attr_reader :retry_after, :polling_metrics, :provider_error_detail

    def initialize(message = nil, retry_after: nil, polling_metrics: nil, provider_error_detail: nil)
      super(message)
      @retry_after = retry_after
      @polling_metrics = polling_metrics || {}
      @provider_error_detail = provider_error_detail || {}
    end
  end
end
