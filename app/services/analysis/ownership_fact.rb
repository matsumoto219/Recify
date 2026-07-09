module Analysis
  OwnershipFact = Struct.new(
    :owner,
    :fact_type,
    :kind,
    :effect_scope,
    :amount,
    :sign,
    :tax_rate,
    :tax_rate_source,
    :source_refs,
    :action,
    :review_reasons,
    :diagnostics,
    :attributes,
    :origin,
    keyword_init: true
  ) do
    def persist?
      action == :persist
    end
  end
end
