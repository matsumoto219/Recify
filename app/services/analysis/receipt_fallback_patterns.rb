module Analysis
  module ReceiptFallbackPatterns
    module_function

    def detect_payment_method(text, profile: ReceiptAnalysisProfiles.default)
      normalized_text = normalize_text(text)
      return nil if normalized_text.blank?
      return nil if payment_noise_only?(normalized_text, profile: profile)

      detect_by_patterns(normalized_text, profile.fallback_payment_method_patterns) || "other"
    end

    def detect_category(text, profile: ReceiptAnalysisProfiles.default)
      normalized_text = normalize_text(text)
      return nil if normalized_text.blank?

      detect_by_patterns(normalized_text, profile.fallback_item_category_patterns) || "other"
    end

    def detect_by_patterns(text, patterns)
      patterns.each do |key, pattern_list|
        Array(pattern_list).each do |pattern|
          return key if text.match?(pattern)
        end
      end

      nil
    end

    def normalize_text(text)
      return nil if text.blank?

      text.to_s.unicode_normalize(:nfkc).downcase.gsub(/[[:space:]]+/, " ").strip.presence
    end

    def payment_noise_only?(text, profile: ReceiptAnalysisProfiles.default)
      has_exclusion = profile.fallback_payment_method_exclusion_patterns.any? { |pattern| text.match?(pattern) }
      has_payment_signal = detect_by_patterns(text, profile.fallback_payment_method_patterns).present?
      support_only = profile.fallback_payment_method_support_only_patterns.any? { |pattern| text.match?(pattern) } &&
        !text.match?(profile.fallback_payment_method_transaction_context_pattern)

      support_only || (has_exclusion && !has_payment_signal)
    end
  end
end
