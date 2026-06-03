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
          body = RequestBuilder.build(input)
          response = post_request(body)

          payload = ResponseParser.parse(attach_response_metrics(response, request_body: body))
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
            metrics: error_metrics(provider_status: "timeout")
          )
        rescue Ai::Errors::ProviderError => e
          raise e
        rescue StandardError => e
          raise Ai::Errors::ProviderError.new(
            message: e.message,
            error_code: "ai_api_error",
            provider: PROVIDER_NAME,
            category: :api_error,
            retryable: true,
            fallbackable: true,
            cause: e,
            provider_status: "unexpected_error",
            metrics: error_metrics(provider_status: "unexpected_error")
          )
        end

        def retry_policy
          @retry_policy ||= Ai::RetryPolicy.new(
            max_retries: max_retries,
            backoff_policy: backoff_policy
          )
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

          if auth_error_response?(response)
            raise Ai::Errors::AuthError.new(
              message: "OpenAI API auth error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              category: :auth,
              retryable: false,
              fallbackable: false,
              provider_status: response.code,
              metrics: error_metrics(provider_status: response.code, request_body: body)
            )
          end

          if rate_limit_response?(response)
            raise Ai::Errors::RateLimitError.new(
              message: "OpenAI API rate limit error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              category: :rate_limit,
              retryable: true,
              fallbackable: true,
              retry_after: retry_after_from_response(response),
              provider_status: response.code,
              metrics: error_metrics(provider_status: response.code, request_body: body, rate_limited: true)
            )
          end

          if server_error_response?(response)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API retryable server error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              category: :server_error,
              retryable: true,
              fallbackable: true,
              retry_after: retry_after_from_response(response),
              provider_status: response.code,
              metrics: error_metrics(provider_status: response.code, request_body: body)
            )
          end

          unless response.is_a?(Net::HTTPSuccess)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME,
              category: :api_error,
              retryable: true,
              fallbackable: true,
              provider_status: response.code,
              metrics: error_metrics(provider_status: response.code, request_body: body)
            )
          end

          parse_response_body(response.body, provider_status: response.code, request_body: body)
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

        def backoff_policy
          @backoff_policy ||= Ai::BackoffPolicy.new(
            base_delay: base_retry_delay,
            max_delay: max_retry_delay
          )
        end

        def parse_response_body(body, provider_status: nil, request_body: nil)
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise Ai::Errors::InvalidResponseError.new(
            message: "Invalid JSON response from OpenAI",
            error_code: "ai_invalid_response",
            provider: PROVIDER_NAME,
            category: :invalid_response,
            retryable: false,
            fallbackable: false,
            cause: e,
            provider_status: "invalid_json",
            metrics: error_metrics(provider_status: provider_status || "invalid_json", request_body: request_body)
          )
        end

        def attach_response_metrics(response, request_body:)
          return response unless response.is_a?(Hash)

          response.merge(
            Ai::ProviderMetrics::METADATA_KEY => response_metrics(response, request_body: request_body)
          )
        end

        def response_metrics(response, request_body:)
          Ai::ProviderMetrics.build(
            provider: PROVIDER_NAME,
            provider_status: "200",
            response_id: response["id"] || response[:id],
            model: response["model"] || response[:model] || request_model(request_body),
            token_usage: extract_token_usage(response)
          )
        end

        def error_metrics(provider_status:, request_body: nil, rate_limited: false)
          Ai::ProviderMetrics.build(
            provider: PROVIDER_NAME,
            model: request_model(request_body),
            provider_status: provider_status,
            rate_limited: rate_limited
          )
        end

        def extract_token_usage(response)
          usage = response["usage"] || response[:usage]
          return {} unless usage.respond_to?(:to_h)

          Ai::ProviderMetrics.token_usage(usage)
        end

        def request_model(body)
          return unless body.respond_to?(:[])

          body[:model] || body["model"]
        end
      end
    end
  end
end
