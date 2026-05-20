require "faraday"
require "json"

module Ocr
  class Client
    DEFAULT_TIMEOUT = 15
    # NOTE:
    # 現時点では単純な固定間隔 polling。
    # Azure 側の解析完了が遅い場合は、この間隔や回数が先にボトルネックになる。
    # 将来は backoff や provider ごとの最適値調整を検討する。
    POLL_INTERVAL = 1.0
    # NOTE:
    # 受信JSONの行数上限ではなく、まずは polling 上限が実運用上のボトルネックになりやすい。
    # レスポンスが大きい場合や Azure 側が混雑している場合、ここが短すぎると ocr_timeout になる。
    # 現時点では保守的な初期値とし、実データを見ながら後で調整する。
    MAX_POLL = 10
    MAX_RETRIES = 2
    BASE_RETRY_DELAY = 0.5
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
    # available? は将来の外部サービス監視ジョブ用の診断メソッド。
    # 通常のOCR処理前には毎回呼ばない。
    # UI表示や通常リクエストでは state cache / ExternalServiceStatus を参照する想定。
    # provider ごとに診断方法が異なるため、必要になった時点で監視専用実装へ切り出す。
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
        f.options.timeout = DEFAULT_TIMEOUT
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
      MAX_POLL.times do
        sleep POLL_INTERVAL

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
        raise if attempts > MAX_RETRIES

        Rails.logger.warn(
          "[OCR::Client] retry operation=#{operation} attempt=#{attempts} error_code=#{error_code_for(e)} class=#{e.class}"
        )
        sleep(retry_delay_for(attempts))
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

    def retry_delay_for(attempt)
      BASE_RETRY_DELAY * (2**(attempt - 1))
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

    # TODO:
    # Azure Document Intelligence の疎通確認は provider 依存が強いため、
    # 将来は監視専用クラス or job 側へ切り出す。
    # 現時点では client 内に置いているが、通常処理フローからは直接使わない前提。
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

      raise(error_code == "ocr_timeout" ? OcrTimeoutError : OcrError, error_code)
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
  end

  class OcrError < StandardError; end
  class OcrTimeoutError < StandardError; end
end
