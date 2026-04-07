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
      Rails.logger.error("[OCR::Client] connection failed class=#{e.class} message=#{e.message}")
      raise OcrError, "external_service_unavailable"
    rescue OcrError, OcrTimeoutError
      raise
    rescue StandardError => e
      Rails.logger.error("[OCR::Client] request failed class=#{e.class} message=#{e.message}")
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
      res = connection.post do |req|
        req.url analyze_path
        req.headers["Ocp-Apim-Subscription-Key"] = api_key
        req.headers["Content-Type"] = "application/octet-stream"
        req.body = image.read
      end

      handle_response_status!(res)

      op_location = res.headers["operation-location"] || res.headers["Operation-Location"]
      raise OcrError, "ocr_invalid_response" if op_location.blank?

      op_location
    end

    def poll_result(op_location)
      MAX_POLL.times do
        sleep POLL_INTERVAL

        res = Faraday.get(op_location) do |req|
          req.headers["Ocp-Apim-Subscription-Key"] = api_key
        end

        handle_response_status!(res)

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
        "[OCR::Client] bad response status=#{res.status} error_code=#{error_code} body=#{truncate_body(res.body)}"
      )

      raise(error_code == "ocr_timeout" ? OcrTimeoutError : OcrError, error_code)
    end

    # NOTE:
    # ログ出力だけは肥大化防止のため切り詰める。
    # これはデバッグログ用であり、OCR本文の受信内容そのものを制限する処理ではない。
    def truncate_body(body)
      body.to_s.tr("\n", " ")[0, 500]
    end

    def endpoint
      ENV.fetch("AZURE_OCR_ENDPOINT")
    end

    def analyze_path
      "/documentintelligence/documentModels/prebuilt-receipt:analyze?api-version=2024-11-30"
    end

    def api_key
      ENV.fetch("AZURE_OCR_API_KEY")
    end
  end

  class OcrError < StandardError; end
  class OcrTimeoutError < StandardError; end
end
