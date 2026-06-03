require "net/http"
require "uri"
require "json"
require "time"

module Ai
  module Providers
    module Openai
      class Client < Ai::Providers::Base
        PROVIDER_NAME = "openai".freeze
        ENDPOINT = "https://api.openai.com/v1/responses".freeze
        DEFAULT_OPEN_TIMEOUT = 10
        DEFAULT_READ_TIMEOUT = 120
        DEFAULT_MAX_RETRIES = 2
        DEFAULT_BASE_RETRY_DELAY = 1.0
        DEFAULT_MAX_RETRY_DELAY = 10.0

        MAX_RETRIES = DEFAULT_MAX_RETRIES
        BASE_RETRY_DELAY = DEFAULT_BASE_RETRY_DELAY
        MAX_RETRY_DELAY = DEFAULT_MAX_RETRY_DELAY

        def call(input)
          reset_metrics!
          body = RequestBuilder.build(input)
          track_request_metrics!(body)

          response = with_retries do
            post_request(body)
          end

          payload = ResponseParser.parse(attach_metrics(response))
          Ai::ProviderResult.new(
            provider: PROVIDER_NAME,
            model: payload.dig(:meta, :model),
            payload: payload,
            metrics: payload.dig(:meta, :metrics),
            response_id: payload.dig(:meta, :response_id)
          )
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          raise Ai::Errors::TimeoutError.new(
            message: e.message,
            provider: PROVIDER_NAME,
            cause: e,
            metrics: finalized_metrics(provider_status: "timeout")
          )
        rescue Ai::Errors::ProviderError => e
          raise enrich_error_with_metrics(e)
        rescue StandardError => e
          raise Ai::Errors::ProviderError.new(
            message: e.message,
            error_code: "ai_api_error",
            provider: PROVIDER_NAME,
            cause: e,
            metrics: finalized_metrics(provider_status: "unexpected_error")
          )
        ensure
          reset_metrics!
        end

        private

        def post_request(body)
          uri = URI.parse(ENDPOINT)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout

          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = JSON.generate(body)

          response = http.request(request)
          track_provider_status!(response.code)

          if auth_error_response?(response)
            raise Ai::Errors::AuthError.new(
              message: "OpenAI API auth error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              metrics: finalized_metrics(provider_status: response.code)
            )
          end

          if rate_limit_response?(response)
            track_rate_limit_metrics!

            raise Ai::Errors::RateLimitError.new(
              message: "OpenAI API rate limit error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              retry_after: retry_after_from_response(response),
              metrics: finalized_metrics(provider_status: response.code)
            )
          end

          if server_error_response?(response)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API retryable server error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              retry_after: retry_after_from_response(response),
              metrics: finalized_metrics(provider_status: response.code)
            )
          end

          unless response.is_a?(Net::HTTPSuccess)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              metrics: finalized_metrics(provider_status: response.code)
            )
          end

          parsed_body = parse_response_body(response.body)
          track_response_metrics!(parsed_body)
          parsed_body
        end

        def with_retries
          attempts = 0

          begin
            attempts += 1
            yield
          rescue Net::OpenTimeout, Net::ReadTimeout, Ai::Errors::ProviderError => e
            raise unless retry_policy.retryable?(e)
            raise if attempts > retry_policy.max_retries

            delay = retry_policy.delay_for(attempt: attempts, error: e)
            track_retry_metrics!(error: e, delay: delay)
            sleep(delay)
            retry
          end
        end

        def auth_error_response?(response)
          [ 401, 403 ].include?(response.code.to_i)
        end

        def rate_limit_response?(response)
          response.code.to_i == 429
        end

        def server_error_response?(response)
          response.code.to_i >= 500
        end

        def retry_after_from_response(response)
          value = response["Retry-After"]
          return if value.blank?

          backoff_policy.parse_retry_after(value)
        end

        def headers
          {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{api_key}"
          }
        end

        def api_key
          ENV.fetch("OPENAI_API_KEY") do
            raise Ai::Errors::AuthError.new(
              message: "OPENAI_API_KEY is not set",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME
            )
          end
        end

        def open_timeout
          ENV.fetch("OPENAI_OPEN_TIMEOUT") do
            ENV.fetch("OPENAI_TIMEOUT", DEFAULT_OPEN_TIMEOUT)
          end.to_i
        end

        def read_timeout
          ENV.fetch("OPENAI_READ_TIMEOUT") do
            ENV.fetch("OPENAI_TIMEOUT", DEFAULT_READ_TIMEOUT)
          end.to_i
        end

        def max_retries
          ENV.fetch("OPENAI_MAX_RETRIES", DEFAULT_MAX_RETRIES).to_i
        end

        def base_retry_delay
          ENV.fetch("OPENAI_BASE_RETRY_DELAY", DEFAULT_BASE_RETRY_DELAY).to_f
        end

        def max_retry_delay
          ENV.fetch("OPENAI_MAX_RETRY_DELAY", DEFAULT_MAX_RETRY_DELAY).to_f
        end

        def retry_policy
          @retry_policy ||= Ai::RetryPolicy.new(
            max_retries: max_retries,
            backoff_policy: backoff_policy
          )
        end

        def backoff_policy
          @backoff_policy ||= Ai::BackoffPolicy.new(
            base_delay: base_retry_delay,
            max_delay: max_retry_delay
          )
        end

        def parse_response_body(body)
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise Ai::Errors::InvalidResponseError.new(
            message: "Invalid JSON response from OpenAI",
            error_code: "ai_invalid_response",
            provider: PROVIDER_NAME,
            cause: e,
            metrics: finalized_metrics(provider_status: "invalid_json")
          )
        end

        def reset_metrics!
          @metrics_started_at = nil
          @current_metrics = nil
          @provider_status = nil
        end

        def ensure_metrics!
          return if @current_metrics.present?

          @metrics_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @current_metrics = Ai::ProviderMetrics.build(
            provider: PROVIDER_NAME,
            retry_count: 0,
            retry_after_used: false,
            total_retry_sleep_ms: 0,
            rate_limited: false
          )
        end

        def track_request_metrics!(body)
          ensure_metrics!
          @current_metrics = Ai::ProviderMetrics.merge(@current_metrics, model: body[:model] || body["model"])
        end

        def track_provider_status!(status)
          return unless @current_metrics.present?

          @provider_status = status.to_s
          @current_metrics = Ai::ProviderMetrics.merge(@current_metrics, provider_status: @provider_status)
        end

        def track_rate_limit_metrics!
          return unless @current_metrics.present?

          @current_metrics = Ai::ProviderMetrics.merge(@current_metrics, rate_limited: true)
        end

        def track_retry_metrics!(error:, delay:)
          ensure_metrics!
          track_rate_limit_metrics! if error.is_a?(Ai::Errors::RateLimitError)
          @current_metrics = Ai::ProviderMetrics.merge(
            @current_metrics,
            retry_count: @current_metrics.fetch(:retry_count, 0).to_i + 1,
            retry_after_used: @current_metrics[:retry_after_used] == true || retry_policy.retry_after_for(error).present?,
            total_retry_sleep_ms: @current_metrics.fetch(:total_retry_sleep_ms, 0).to_i + (delay.to_f * 1000).round
          )
        end

        def track_response_metrics!(response)
          return unless response.is_a?(Hash)

          @current_metrics = Ai::ProviderMetrics.merge(
            @current_metrics,
            response_id: response["id"] || response[:id],
            model: response["model"] || response[:model],
            token_usage: extract_token_usage(response)
          )
        end

        def attach_metrics(response)
          return response unless response.is_a?(Hash)

          response.merge(Ai::ProviderMetrics::METADATA_KEY => finalized_metrics(response: response))
        end

        def finalized_metrics(response: nil, provider_status: nil)
          ensure_metrics!

          values = {
            elapsed_ms: elapsed_ms,
            provider_status: provider_status || @provider_status
          }

          if response.is_a?(Hash)
            values.merge!(
              response_id: response["id"] || response[:id],
              model: response["model"] || response[:model],
              token_usage: extract_token_usage(response)
            )
          end

          Ai::ProviderMetrics.merge(@current_metrics, values)
        end

        def enrich_error_with_metrics(error)
          metrics = Ai::ProviderMetrics.merge(finalized_metrics(provider_status: error_provider_status(error)), error.metrics)
          metrics = Ai::ProviderMetrics.merge(metrics, rate_limited: true) if error.is_a?(Ai::Errors::RateLimitError)

          if error.is_a?(Ai::Errors::TimeoutError)
            return Ai::Errors::TimeoutError.new(
              message: error.message,
              provider: error.provider || PROVIDER_NAME,
              cause: error.cause,
              metrics: metrics
            )
          end

          error.class.new(
            message: error.message,
            error_code: error.error_code,
            provider: error.provider || PROVIDER_NAME,
            cause: error.cause,
            retry_after: error.retry_after,
            metrics: metrics
          )
        end

        def error_provider_status(error)
          return "rate_limited" if error.is_a?(Ai::Errors::RateLimitError)
          return "timeout" if error.is_a?(Ai::Errors::TimeoutError)
          return "invalid_response" if error.is_a?(Ai::Errors::InvalidResponseError)

          @provider_status || error.error_code
        end

        def elapsed_ms
          return unless @metrics_started_at

          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @metrics_started_at) * 1000).round
        end

        def extract_token_usage(response)
          usage = response["usage"] || response[:usage]
          return {} unless usage.respond_to?(:to_h)

          Ai::ProviderMetrics.token_usage(usage)
        end
      end
    end
  end
end
