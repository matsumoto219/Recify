require "net/http"
require "uri"
require "json"

module Ai
  module Providers
    module Openai
      class Client < Ai::Providers::Base
        PROVIDER_NAME = "openai".freeze
        ENDPOINT = "https://api.openai.com/v1/responses".freeze
        DEFAULT_OPEN_TIMEOUT = 10
        DEFAULT_READ_TIMEOUT = 30
        MAX_RETRIES = 2
        BASE_RETRY_DELAY = 1.0

        def call(input)
          body = RequestBuilder.build(input)
          response = with_retries do
            post_request(body)
          end
          ResponseParser.parse(response)
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          raise Ai::Errors::TimeoutError.new(
            message: e.message,
            provider: PROVIDER_NAME,
            cause: e
          )
        rescue Ai::Errors::AuthError, Ai::Errors::RateLimitError,
               Ai::Errors::InvalidResponseError, Ai::Errors::ProviderError
          raise
        rescue StandardError => e
          raise Ai::Errors::ProviderError.new(
            message: e.message,
            error_code: "ai_api_error",
            provider: PROVIDER_NAME,
            cause: e
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
              provider: PROVIDER_NAME
            )
          end

          if rate_limit_response?(response)
            raise Ai::Errors::RateLimitError.new(
              message: "OpenAI API rate limit error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME
            )
          end

          if server_error_response?(response)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API retryable server error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME
            )
          end

          unless response.is_a?(Net::HTTPSuccess)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API error: #{response.code}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME
            )
          end

          parse_response_body(response.body)
        end

        def with_retries
          attempts = 0

          begin
            attempts += 1
            yield
          rescue Net::OpenTimeout, Net::ReadTimeout, Ai::Errors::ProviderError => e
            raise unless retryable_error?(e)
            raise if attempts > MAX_RETRIES

            sleep(retry_delay_for(attempts))
            retry
          end
        end

        def retryable_error?(error)
          case error
          when Net::OpenTimeout, Net::ReadTimeout
            true
          when Ai::Errors::RateLimitError
            true
          when Ai::Errors::ProviderError
            error.error_code == "ai_api_error"
          else
            false
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

        def retry_delay_for(attempt)
          BASE_RETRY_DELAY * (2**(attempt - 1))
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

        def parse_response_body(body)
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise Ai::Errors::InvalidResponseError.new(
            message: "Invalid JSON response from OpenAI",
            error_code: "ai_invalid_response",
            provider: PROVIDER_NAME,
            cause: e
          )
        end
      end
    end
  end
end
