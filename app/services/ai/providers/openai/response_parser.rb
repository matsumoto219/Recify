require "json"

module Ai
  module Providers
    module Openai
      class ResponseParser
        class << self
          def parse(response)
            new(response).parse
          end
        end

        def initialize(response)
          @response = response || {}
        end

        def parse
          parsed_body = normalized_response_body
          payload = extract_json_payload(parsed_body)

          Ai::ResponseParser.parse(
            payload,
            provider: "openai",
            meta: build_meta(parsed_body)
          )
        rescue JSON::ParserError => e
          raise Ai::Errors::InvalidResponseError.new(
            message: "Failed to parse OpenAI JSON payload",
            error_code: "ai_invalid_response",
            provider: "openai",
            cause: e
          )
        rescue Ai::Errors::InvalidResponseError, Ai::Errors::ProviderError
          raise
        rescue StandardError => e
          raise Ai::Errors::InvalidResponseError.new(
            message: "Failed to parse OpenAI response",
            error_code: "ai_invalid_response",
            provider: "openai",
            cause: e
          )
        end

        private

        attr_reader :response

        def normalized_response_body
          return response if response.is_a?(Hash)
          return JSON.parse(response) if response.is_a?(String)

          raise Ai::Errors::InvalidResponseError.new(
            message: "OpenAI response must be a Hash or JSON string",
            error_code: "ai_invalid_response",
            provider: "openai"
          )
        end

        def extract_json_payload(body)
          output_text = direct_output_text(body)
          return JSON.parse(output_text) if output_text.present?

          output_text = nested_output_text(body)
          return JSON.parse(output_text) if output_text.present?

          if body["store"].is_a?(Hash) || body[:store].is_a?(Hash)
            return stringify_keys(body.except(Ai::ProviderMetrics::METADATA_KEY))
          end

          raise Ai::Errors::InvalidResponseError.new(
            message: "OpenAI response did not contain a JSON payload",
            error_code: "ai_invalid_response",
            provider: "openai"
          )
        end

        def direct_output_text(body)
          body["output_text"] || body[:output_text]
        end

        def nested_output_text(body)
          Array(body["output"] || body[:output]).each do |item|
            Array(item["content"] || item[:content]).each do |content|
              text = content["text"] || content[:text]
              return text if text.present?
            end
          end

          nil
        end

        def build_meta(body)
          {
            provider: "openai",
            response_id: body["id"] || body[:id],
            model: body["model"] || body[:model],
            metrics: response_metrics(body).presence
          }.compact
        end

        def response_metrics(body)
          metrics = body[Ai::ProviderMetrics::METADATA_KEY] || body[:recify_ai_metrics] || {}
          return {} if metrics.blank? && token_usage(body).blank?

          Ai::ProviderMetrics.merge(
            metrics,
            response_id: body["id"] || body[:id],
            model: body["model"] || body[:model],
            token_usage: token_usage(body)
          )
        end

        def token_usage(body)
          Ai::ProviderMetrics.token_usage(body["usage"] || body[:usage])
        end

        def error_meta(error)
          {
            provider: "openai",
            error_class: error.class.name,
            error_message: error.message
          }.merge(build_meta(response.is_a?(Hash) ? response : {})).compact
        end

        def stringify_keys(object)
          return object unless object.is_a?(Hash)

          object.deep_stringify_keys
        end
      end
    end
  end
end
