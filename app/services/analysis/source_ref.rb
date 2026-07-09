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
  end
end
