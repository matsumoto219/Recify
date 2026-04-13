module Ai
  module Providers
    module Openai
      class RequestBuilder
        DEFAULT_MODEL = "gpt-5.4-mini".freeze

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
              format: {
                type: "json_object"
              }
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
          ENV.fetch("OPENAI_AI_MODEL", DEFAULT_MODEL)
        end

        def ai_name_completion_enabled?
          input.respond_to?(:with_indifferent_access) &&
            input.with_indifferent_access.dig(:meta, :ai_name_completion_enabled) == true
        end
      end
    end
  end
end
