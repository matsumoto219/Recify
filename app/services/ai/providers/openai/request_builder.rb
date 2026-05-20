module Ai
  module Providers
    module Openai
      class RequestBuilder
        class << self
          def build(input)
            new(input).build
          end
        end

        def initialize(input)
          @input = input || {}
        end

        def build
          prompt = Ai::PromptTemplate.build(input)

          request = {
            model: model_name,
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

          if ai_name_completion_enabled?
            request[:reasoning] = {
              effort: "medium"
            }
          end

          request
        end

        private

        attr_reader :input

        def model_name
          ENV.fetch("OPENAI_AI_MODEL")
        end

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
