require "json"

module Ai
  module Providers
    module Openai
      class ResponseParser
        class << self
          def parse(response, provider_response: false)
            new(response, provider_response: provider_response).parse
          end
        end

        def initialize(response, provider_response: false)
          @response = response || {}
          @provider_response = provider_response
        end

        def parse
          metrics = {}
          parsed_body = normalized_response_body
          metrics = response_metrics(parsed_body)
          validate_response!(parsed_body)
          payload = extract_json_payload(parsed_body)

          Ai::ResponseParser.parse(
            payload,
            provider: "openai",
            meta: build_meta(parsed_body, metrics: metrics)
          )
        rescue JSON::ParserError => e
          raise Ai::Errors::InvalidResponseError.new(
            message: "Failed to parse OpenAI JSON payload",
            error_code: "ai_invalid_response",
            provider: "openai",
            **diagnostic_attributes(local_issue: "invalid_json"),
            metrics: metrics,
            cause: e
          )
        rescue Ai::Errors::ProviderError => e
          e.metrics.replace(Ai::ProviderMetrics.merge(metrics, e.metrics))
          raise
        rescue StandardError => e
          raise Ai::Errors::InvalidResponseError.new(
            message: "Failed to parse OpenAI response",
            error_code: "ai_invalid_response",
            provider: "openai",
            **diagnostic_attributes(local_issue: "invalid_response"),
            metrics: metrics,
            cause: e
          )
        end

        private

        attr_reader :response, :provider_response

        def normalized_response_body
          return response if response.is_a?(Hash)
          return JSON.parse(response) if response.is_a?(String)

          raise Ai::Errors::InvalidResponseError.new(
            message: "OpenAI response must be a Hash or JSON string",
            error_code: "ai_invalid_response",
            provider: "openai",
            **diagnostic_attributes(local_issue: "invalid_response")
          )
        end

        def extract_json_payload(body)
          output_text = direct_output_text(body)
          return JSON.parse(output_text) if output_text.present?

          output_text = nested_output_text(body)
          return JSON.parse(output_text) if output_text.present?

          if !provider_response && !response_envelope?(body) && (body["store"].is_a?(Hash) || body[:store].is_a?(Hash))
            return stringify_keys(body.except(Ai::ProviderMetrics::METADATA_KEY))
          end

          raise Ai::Errors::InvalidResponseError.new(
            message: "OpenAI response did not contain a JSON payload",
            error_code: "ai_invalid_response",
            provider: "openai",
            **diagnostic_attributes(local_issue: "invalid_response")
          )
        end

        def validate_response!(body)
          return unless provider_response || response_envelope?(body)

          unless (body["status"] || body[:status]) == "completed"
            raise Ai::Errors::InvalidResponseError.new(
              message: "OpenAI response was not completed",
              provider: "openai",
              **diagnostic_attributes(
                body: body,
                local_issue: (body["status"] || body[:status]) == "incomplete" ? "incomplete" : "invalid_response"
              )
            )
          end
          return unless refusal_response?(body)

          raise Ai::Errors::InvalidResponseError.new(
            message: "OpenAI response contained a refusal",
            provider: "openai",
            **diagnostic_attributes(local_issue: "refusal")
          )
        end

        def diagnostic_attributes(body: nil, local_issue:)
          error_body = body.slice("error", :error, "incomplete_details", :incomplete_details).compact if body.is_a?(Hash)
          detail = ExternalServices.error_detail(
            service: :ai,
            provider: "openai",
            phase: :ai_response,
            body: error_body,
            local_issue: local_issue
          )

          {
            provider_error_code: detail[:provider_error_code],
            provider_error_type: detail[:provider_error_type],
            provider_message: detail[:provider_message_safe],
            phase: detail[:phase],
            diagnostic: detail[:diagnostic]
          }.compact
        end

        def response_envelope?(body)
          %w[object status output incomplete_details].any? { |key| body.key?(key) || body.key?(key.to_sym) }
        end

        def refusal_response?(body)
          Array(body["output"] || body[:output]).any? do |item|
            next false unless item.is_a?(Hash)

            Array(item["content"] || item[:content]).any? do |content|
              content.is_a?(Hash) && (content["type"] || content[:type]) == "refusal"
            end
          end
        end

        def direct_output_text(body)
          body["output_text"] || body[:output_text]
        end

        def nested_output_text(body)
          Array(body["output"] || body[:output]).each do |item|
            next unless item.is_a?(Hash)
            next unless [ nil, "message" ].include?(item["type"] || item[:type])

            Array(item["content"] || item[:content]).each do |content|
              next unless content.is_a?(Hash)
              next unless (content["type"] || content[:type]) == "output_text"

              text = content["text"] || content[:text]
              return text if text.present?
            end
          end

          nil
        end

        def build_meta(body, metrics:)
          {
            provider: "openai",
            response_id: body["id"] || body[:id],
            model: body["model"] || body[:model],
            metrics: metrics.presence
          }.compact
        end

        def response_metrics(body)
          metrics = body[Ai::ProviderMetrics::METADATA_KEY] || body[:recify_ai_metrics] || {}
          usage = token_usage(body)
          status = body["status"] || body[:status]
          incomplete_details = body["incomplete_details"] || body[:incomplete_details]
          incomplete_reason = incomplete_details["reason"] || incomplete_details[:reason] if incomplete_details.is_a?(Hash)
          return {} if metrics.blank? && usage.blank? && status.blank? && incomplete_reason.blank?

          Ai::ProviderMetrics.merge(
            metrics,
            response_id: body["id"] || body[:id],
            model: body["model"] || body[:model],
            response_status: status,
            incomplete_reason: incomplete_reason,
            token_usage: usage.presence
          )
        end

        def token_usage(body)
          usage = body["usage"] || body[:usage]
          return {} unless usage.is_a?(Hash)

          usage = usage.with_indifferent_access
          output_details = usage[:output_tokens_details]
          input_details = usage[:input_tokens_details]
          details = {
            reasoning_tokens: output_details.is_a?(Hash) ? output_details[:reasoning_tokens] : nil,
            cached_input_tokens: input_details.is_a?(Hash) ? input_details[:cached_tokens] : nil
          }.compact
          Ai::ProviderMetrics.token_usage(usage.merge(details))
        end

        def stringify_keys(object)
          return object unless object.is_a?(Hash)

          object.deep_stringify_keys
        end
      end
    end
  end
end
