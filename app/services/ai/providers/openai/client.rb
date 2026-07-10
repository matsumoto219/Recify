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

        def initialize(runtime_config: nil)
          @runtime_config = runtime_config || ExternalServices.runtime_config_snapshot.ai
        end

        def call(input, before_provider_call: nil)
          body = RequestBuilder.build(input)
          response =
            if before_provider_call
              post_request(body, before_provider_call: before_provider_call)
            else
              post_request(body)
            end

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
        rescue Usage::LimitExceeded
          raise
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

        attr_reader :runtime_config

        def post_request(body, before_provider_call: nil)
          uri = URI.parse(ENDPOINT)
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = open_timeout
          http.read_timeout = read_timeout

          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = JSON.generate(body)
          before_provider_call&.call

          response = http.request(request)
          error_detail = provider_error_detail(response, request_body: body)

          if quota_exceeded_response?(response, error_detail)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API quota exceeded: #{response.code}",
              error_code: "ai_quota_exceeded",
              provider: PROVIDER_NAME,
              category: :billing_quota,
              retryable: false,
              fallbackable: true,
              retry_after: retry_after_from_response(response),
              provider_status: response.code,
              **provider_error_attributes(error_detail),
              metrics: error_metrics(provider_status: response.code, request_body: body, error_detail: error_detail)
            )
          end

          if auth_error_response?(response)
            raise Ai::Errors::AuthError.new(
              message: "OpenAI API auth error: #{response.code}",
              error_code: "ai_auth_error",
              provider: PROVIDER_NAME,
              category: :auth,
              retryable: false,
              fallbackable: false,
              provider_status: response.code,
              **provider_error_attributes(error_detail.merge(auth_error: true)),
              metrics: error_metrics(provider_status: response.code, request_body: body, error_detail: error_detail.merge(auth_error: true))
            )
          end

          if rate_limit_response?(response)
            raise Ai::Errors::RateLimitError.new(
              message: "OpenAI API rate limit error: #{response.code}",
              error_code: "ai_rate_limited",
              provider: PROVIDER_NAME,
              category: :rate_limit,
              retryable: true,
              fallbackable: true,
              retry_after: retry_after_from_response(response),
              provider_status: response.code,
              **provider_error_attributes(error_detail.merge(rate_limited: true)),
              metrics: error_metrics(provider_status: response.code, request_body: body, error_detail: error_detail.merge(rate_limited: true))
            )
          end

          if invalid_request_response?(response)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API invalid request: #{response.code}",
              error_code: "ai_invalid_request",
              provider: PROVIDER_NAME,
              category: :invalid_request,
              retryable: false,
              fallbackable: false,
              provider_status: response.code,
              **provider_error_attributes(error_detail),
              metrics: error_metrics(provider_status: response.code, request_body: body, error_detail: error_detail)
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
              **provider_error_attributes(error_detail),
              metrics: error_metrics(provider_status: response.code, request_body: body, error_detail: error_detail)
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
              **provider_error_attributes(error_detail),
              metrics: error_metrics(provider_status: response.code, request_body: body, error_detail: error_detail)
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

        def quota_exceeded_response?(response, error_detail)
          response.code.to_i == 429 && error_detail[:quota_exceeded] == true
        end

        def invalid_request_response?(response)
          response.code.to_i == 400 || response.code.to_i == 422
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
              error_code: "ai_auth_error",
              provider: PROVIDER_NAME,
              category: :auth,
              retryable: false,
              fallbackable: false,
              provider_status: "configuration",
              provider_error_code: "api_key_missing",
              provider_error_type: "configuration",
              provider_message: "OpenAI API key is missing",
              auth_error: true,
              phase: "configuration",
              metrics: error_metrics(
                provider_status: "configuration",
                error_detail: {
                  provider_error_code: "api_key_missing",
                  provider_error_type: "configuration",
                  provider_message_safe: "OpenAI API key is missing",
                  auth_error: true,
                  phase: "configuration"
                }
              )
            )
          end
        end

        def open_timeout
          runtime_config.open_timeout_seconds
        end

        def read_timeout
          runtime_config.read_timeout_seconds
        end

        def max_retries
          runtime_config.max_retries
        end

        def base_retry_delay
          runtime_config.base_retry_delay_seconds
        end

        def max_retry_delay
          runtime_config.max_retry_delay_seconds
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

        def provider_error_detail(response, request_body:)
          ExternalServices.error_detail(
            service: :ai,
            provider: PROVIDER_NAME,
            phase: :ai_request,
            http_status: response.code,
            body: response.body,
            headers: response_headers(response),
            retry_after: retry_after_from_response(response),
            model: request_model(request_body)
          )
        end

        def response_headers(response)
          headers = {}
          response.each_header { |key, value| headers[key] = value } if response.respond_to?(:each_header)
          headers
        end

        def provider_error_attributes(error_detail)
          {
            provider_error_code: error_detail[:provider_error_code],
            provider_error_type: error_detail[:provider_error_type],
            provider_message: error_detail[:provider_message_safe],
            request_id: error_detail[:request_id],
            quota_exceeded: error_detail[:quota_exceeded],
            rate_limited: error_detail[:rate_limited],
            auth_error: error_detail[:auth_error],
            phase: error_detail[:phase]
          }.compact
        end

        def error_metrics(provider_status:, request_body: nil, rate_limited: false, error_detail: nil)
          detail = error_detail || {}
          detail_metrics = provider_error_attributes(detail).merge(retry_after: detail[:retry_after]).compact
          Ai::ProviderMetrics.build(
            {
              provider: PROVIDER_NAME,
              model: request_model(request_body),
              provider_status: provider_status,
              rate_limited: rate_limited
            }.merge(detail_metrics)
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
