module SecurityEvents
  module Rules
    class ParameterTamperingRule < Base
      PROTECTED_RECEIPT_FIELDS = %w[
        id
        user_id
        receipt_id
        public_id
        display_id
        status
        processing_error_code
        processing_error_message
        keep_image
        image_purged_at
        image_purged_reason
      ].freeze
      PROTECTED_RECEIPT_NESTED_FIELDS = (PROTECTED_RECEIPT_FIELDS - %w[id]).freeze
      PROTECTED_RECEIPT_TOP_LEVEL_FIELDS = %w[
        amount_calculation_profile
        review_reasons
        safe_to_auto_complete
        selected_candidate_status
      ].freeze
      PROTECTED_USER_FIELDS = %w[
        id
        admin
        role
        guest
        confirmed_at
        locked_at
        failed_attempts
        session_version
        user_limit
        storage_bytes_used
      ].freeze

      def call(param_path:, value:, context: nil)
        matched_rule = matched_rule_for(param_path)
        return [] unless matched_rule

        [
          build_candidate(
            event_type: "parameter_tampering_attempt",
            severity: "medium",
            category: "authorization",
            matched_rule: matched_rule,
            field_name: param_path,
            value_excerpt: value
          )
        ]
      end

      private

      def matched_rule_for(field_name)
        segments = normalized_path_segments(field_name)

        if segments.first == "receipt" && protected_receipt_path?(segments)
          "protected_receipt_attribute"
        elsif segments.first == "user" && (segments & PROTECTED_USER_FIELDS).any?
          "protected_user_attribute"
        end
      end

      def normalized_path_segments(field_name)
        field_name.to_s.split(".").map { |segment| segment.sub(/\[\d+\]\z/, "") }
      end

      def protected_receipt_path?(segments)
        protected_receipt_top_level_path?(segments) ||
          protected_receipt_nested_path?(segments) ||
          PROTECTED_RECEIPT_TOP_LEVEL_FIELDS.include?(segments.second)
      end

      def protected_receipt_top_level_path?(segments)
        segments.size == 2 && PROTECTED_RECEIPT_FIELDS.include?(segments.second)
      end

      def protected_receipt_nested_path?(segments)
        (segments.drop(2) & PROTECTED_RECEIPT_NESTED_FIELDS).any?
      end
    end
  end
end
