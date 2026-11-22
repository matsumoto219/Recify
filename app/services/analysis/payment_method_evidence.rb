module Analysis
  class PaymentMethodEvidence
    MAX_LINES = 150
    MAX_LINE_BYTES = 500
    MAX_SPAN_INDEX = 10_000_000
    METHODS = %w[cash credit_card e_money qr_payment debit_card other].freeze
    INDEX_TYPES = %w[utf16CodeUnit textElements].freeze
    KEYS = %i[
      source_kind method page_index label_line_index method_line_index label_path method_path
      label_span method_span string_index_type
    ].freeze
    SPAN_KEYS = %i[offset length].freeze
    PATH_PATTERN = /\Apages\[(?<page>0|[1-7])\]\.lines\[(?<line>0|[1-9]\d{0,2})\]\z/.freeze

    def self.call(value, lines:, profile:)
      new(lines:, profile:).call(value)
    end

    def initialize(lines:, profile:)
      @lines = lines
      @profile = profile
    end

    def call(value)
      evidence = bounded_hash(value, KEYS)
      return unless evidence && evidence[:source_kind] == "azure_same_row"
      return unless METHODS.include?(evidence[:method]) && INDEX_TYPES.include?(evidence[:string_index_type])
      return unless bounded_integer?(evidence[:page_index], 7) && valid_lines?

      label_index = evidence[:label_line_index]
      method_index = evidence[:method_line_index]
      return unless [ label_index, method_index ].all? { |index| bounded_integer?(index, lines.size - 1) }
      return unless method_index == label_index + 1 && valid_paths?(evidence)

      label_span = normalize_span(evidence[:label_span])
      method_span = normalize_span(evidence[:method_span])
      return unless label_span && method_span && label_span[:offset] + label_span[:length] <= method_span[:offset]
      return unless unique_method?(evidence)

      result = evidence.transform_values { |child| child.is_a?(String) ? child.dup.freeze : child }
      result.merge(label_span: label_span.freeze, method_span: method_span.freeze).freeze
    end

    private

    attr_reader :lines, :profile

    def valid_lines?
      lines.is_a?(Array) && lines.size.between?(2, MAX_LINES) && lines.all? do |line|
        line.is_a?(String) && line.valid_encoding? && line.bytesize.between?(1, MAX_LINE_BYTES) &&
          (line.encoding == Encoding::UTF_8 || line.ascii_only?) &&
          !line.match?(/[\p{Cc}\p{Cf}]/)
      end
    end

    def valid_paths?(evidence)
      paths = %i[label_path method_path].map do |key|
        path = evidence[key]
        return false unless path.is_a?(String) && path.bytesize <= 48 && path.valid_encoding? && path.ascii_only?

        match = PATH_PATTERN.match(path)
        return false unless match && match[:page].to_i == evidence[:page_index] && match[:line].to_i < MAX_LINES

        match[:line].to_i
      end
      paths.last == paths.first + 1
    end

    def unique_method?(evidence)
      return false unless profile.respond_to?(:ocr_payment_method_label_pattern) &&
        profile.respond_to?(:ocr_payment_method_value_patterns) && profile.respond_to?(:ocr_payment_schedule_value_pattern) &&
        profile.respond_to?(:ocr_payment_support_only_pattern)

      label_pattern = profile.ocr_payment_method_label_pattern
      patterns = profile.ocr_payment_method_value_patterns
      schedule_pattern = profile.ocr_payment_schedule_value_pattern
      support_pattern = profile.ocr_payment_support_only_pattern
      return false unless label_pattern.is_a?(Regexp) && schedule_pattern.is_a?(Regexp) && patterns.is_a?(Hash) && patterns.size.between?(1, METHODS.size)
      return false unless support_pattern.is_a?(Regexp)
      return false unless patterns.all? { |method, pattern| METHODS.include?(method) && pattern.is_a?(Regexp) }
      return false if lines.any? { |line| line.gsub(/[[:space:]]+/, "").match?(support_pattern) }

      covered_lines = Array.new(lines.size, false)
      matches = lines.each_with_index.filter_map do |label, index|
        next unless full_match?(label_pattern, label)

        value = lines[index + 1]
        return false unless value

        covered_lines[index] = covered_lines[index + 1] = true
        next if full_match?(schedule_pattern, value)

        methods = patterns.filter_map { |method, pattern| method if full_match?(pattern, value) }
        [ index, methods ]
      end
      matches == [ [ evidence[:label_line_index], [ evidence[:method] ] ] ] && non_conflicting_lines?(covered_lines)
    end

    def non_conflicting_lines?(covered_lines)
      return false unless profile.respond_to?(:analysis_fallback_payment_transaction_context_pattern) &&
        profile.respond_to?(:analysis_return_refund_kind_pattern)

      patterns = [ profile.analysis_fallback_payment_transaction_context_pattern, profile.analysis_return_refund_kind_pattern ]
      return false unless patterns.all? { |pattern| pattern.is_a?(Regexp) }

      lines.each_with_index.none? do |line, index|
        !covered_lines[index] && patterns.any? { |pattern| line.match?(pattern) }
      end
    end

    def full_match?(pattern, value)
      match = pattern.match(value)
      match && match.begin(0).zero? && match.end(0) == value.length
    end

    def normalize_span(value)
      span = bounded_hash(value, SPAN_KEYS)
      return unless span && bounded_integer?(span[:offset], MAX_SPAN_INDEX)
      return unless span[:length].is_a?(Integer) && span[:length].between?(1, MAX_LINE_BYTES) && span[:length] <= MAX_SPAN_INDEX - span[:offset]

      span
    end

    def bounded_integer?(value, maximum)
      value.is_a?(Integer) && value.between?(0, maximum)
    end

    def bounded_hash(value, keys)
      return unless value.is_a?(Hash) && value.size == keys.size
      return unless value.keys.all? { |key| keys.include?(key) || keys.any? { |allowed| key == allowed.to_s } }

      normalized = value.each_with_object({}) { |(key, child), result| result[key.to_sym] = child }
      normalized if normalized.size == keys.size
    end
  end
end
