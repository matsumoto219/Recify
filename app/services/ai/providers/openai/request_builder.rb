module Ai
  module Providers
    module Openai
      class RequestBuilder
        DEFAULT_MODEL = "gpt-4.1-mini".freeze

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
          {
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
        end

        private

        attr_reader :input

        def model_name
          ENV.fetch("OPENAI_AI_MODEL", DEFAULT_MODEL)
        end
      end
    end
  end
end
