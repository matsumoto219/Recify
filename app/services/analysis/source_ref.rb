module Analysis
  SourceRef = Struct.new(
    :provider,
    :field_path,
    :line_index,
    :span_start,
    :span_end,
    :source_text,
    :normalized_text,
    :amount_token,
    :amount_token_kind,
    keyword_init: true
  ) do
    def identity
      [
        provider,
        field_path,
        line_index,
        span_start,
        span_end,
        normalized_text,
        amount_token,
        amount_token_kind
      ]
    end

    def strong_identity
      return unless strong?

      if line_index.nil?
        [ :field, provider, field_path, span_start, span_end, amount_token, amount_token_kind ]
      else
        [ :line, line_index, span_start, span_end, amount_token, amount_token_kind ]
      end
    end

    def strong?
      (field_path.present? || line_index.present?) &&
        span_start.present? &&
        span_end.present? &&
        amount_token.to_i.positive? &&
        %i[money bare_number].include?(amount_token_kind&.to_sym)
    end
  end
end
