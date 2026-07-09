module Analysis
  OwnershipResult = Struct.new(
    :items,
    :adjustments,
    :payments,
    :tax_details,
    :facts,
    :review_reasons,
    :diagnostics,
    keyword_init: true
  )
end
