FactoryBot.define do
  factory :receipt_adjustment do
    association :receipt
    kind { "delivery_fee" }
    label { "配送料" }
    amount { 550 }
    sign { "surcharge" }
    source { "ai" }
    source_text { "配送料 ¥550" }
    source_line_index { 19 }
    confidence { BigDecimal("0.9") }
    needs_review { false }
    review_reasons { [] }
    position_index { 1 }
  end
end
