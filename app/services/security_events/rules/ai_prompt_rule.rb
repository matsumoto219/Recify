module SecurityEvents
  module Rules
    class AiPromptRule < Base
      RULES = [
        {
          event_type: "prompt_injection_attempt",
          severity: "medium",
          matched_rule: "prompt_override_marker",
          pattern: /(?:ignore (?:all )?(?:previous|prior) instructions|system prompt|developer message|you are now|jailbreak|prompt injection)/i
        },
        {
          event_type: "ocr_text_injection_attempt",
          severity: "medium",
          matched_rule: "receipt_instruction_marker",
          pattern: /(?:ignore receipt|override total|do not trust|ai instruction|assistant:|system:)/i
        }
      ].freeze

      def call(param_path:, value:, context: nil)
        RULES.filter_map do |rule|
          next unless rule.fetch(:pattern).match?(value)

          build_candidate(
            event_type: rule.fetch(:event_type),
            severity: rule.fetch(:severity),
            category: "ai",
            matched_rule: rule.fetch(:matched_rule),
            field_name: param_path,
            value_excerpt: value
          )
        end
      end
    end
  end
end
