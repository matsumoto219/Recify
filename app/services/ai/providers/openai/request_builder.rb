module Ai
  module Providers
    module Openai
      class RequestBuilder
        class << self
          def build(input, runtime_config: nil)
            new(input, runtime_config: runtime_config).build
          end
        end

        def initialize(input, runtime_config: nil)
          @input = input || {}
          @runtime_config = runtime_config || ExternalServices.runtime_config_snapshot.ai
        end

        def build
          prompt = Ai::PromptTemplate.build(input)

          request = {
            model: runtime_config.model,
            input: [
              {
                role: "system",
                content: [
                  {
                    type: "input_text",
                    text: prompt[:system]
                  }
                ]
              },
              {
                role: "user",
                content: [
                  {
                    type: "input_text",
                    text: prompt[:user]
                  }
                ]
              }
            ],
            text: {
              format: structured_output_format
            }
          }

          request[:reasoning] = {
            effort: ai_name_completion_enabled? ? runtime_config.name_completion_reasoning_effort : runtime_config.reasoning_effort
          }

          request
        end

        private

        attr_reader :input, :runtime_config

        def ai_name_completion_enabled?
          input.respond_to?(:with_indifferent_access) &&
            input.with_indifferent_access.dig(:meta, :ai_name_completion_enabled) == true
        end

        def structured_output_format
          {
            type: "json_schema",
            name: "recify_receipt_analysis_v1",
            strict: true,
            schema: Ai::ReceiptAnalysisSchema.to_json_schema
          }
        end
      end
    end
  end
end
