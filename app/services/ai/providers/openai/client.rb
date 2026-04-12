require "net/http"
require "uri"
require "json"

module Ai
  module Providers
    module Openai
      class Client < Ai::Providers::Base
        PROVIDER_NAME = "openai".freeze
        ENDPOINT = "https://api.openai.com/v1/responses".freeze
        DEFAULT_TIMEOUT = 10

        def call(input)
          body = RequestBuilder.build(input)
          response = post_request(body)
          ResponseParser.parse(response)
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          raise Ai::Errors::TimeoutError.new(
            message: e.message,
            provider: PROVIDER_NAME,
            cause: e
          )
        rescue Ai::Errors::ProviderError
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
          http.open_timeout = timeout
          http.read_timeout = timeout

          request = Net::HTTP::Post.new(uri.request_uri, headers)
          request.body = JSON.generate(body)

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            raise Ai::Errors::ProviderError.new(
              message: "OpenAI API error: #{response.code} #{response.body}",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME
            )
          end

          parse_response_body(response.body)
        end

        def headers
          {
            "Content-Type" => "application/json",
            "Authorization" => "Bearer #{api_key}"
          }
        end

        def api_key
          ENV.fetch("OPENAI_API_KEY") do
            raise Ai::Errors::ProviderError.new(
              message: "OPENAI_API_KEY is not set",
              error_code: "ai_api_error",
              provider: PROVIDER_NAME
            )
          end
        end

        def timeout
          ENV.fetch("OPENAI_TIMEOUT", DEFAULT_TIMEOUT).to_i
        end

        def parse_response_body(body)
          JSON.parse(body)
        rescue JSON::ParserError => e
          raise Ai::Errors::ProviderError.new(
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
