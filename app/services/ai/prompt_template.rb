module Ai
  class PromptTemplate
    class << self
      def build(input)
        new(input).build
      end
    end

    def initialize(input)
      @input = if input.respond_to?(:with_indifferent_access)
        input.with_indifferent_access
      else
        {}.with_indifferent_access
      end
    end

    def build
      {
        system: system_prompt,
        user: user_prompt
      }
    end

    private

    attr_reader :input

    def system_prompt
      <<~PROMPT
        You are a strict JSON generator for a receipt processing system.

        You MUST follow all rules exactly.

        Output MUST be a valid JSON object.
        Do NOT output anything except JSON.
        Do NOT include markdown fences or explanations.

        Use OCR candidates as the first reference and filtered_content as the supporting reference.

        You MUST NOT:
        - invent store names, addresses, phone numbers, timestamps, or payment methods
        #{system_item_name_rule}
        - guess totals, taxes, quantities, or prices
        - add fields not explicitly allowed
        - change numeric values

        If information is missing or uncertain:
        - return null
        - set needs_review = true

        When correcting values:
        - prioritize correctness over completeness
        - if a field cannot be determined with high confidence, return null or keep the original OCR text instead of guessing

        Follow the schema strictly.
        Any deviation is considered a failure.
      PROMPT
    end

    def user_prompt
      <<~PROMPT
        Return a JSON object with exactly these top-level keys:
        - store
        - purchase
        - payment
        - items
        - needs_review
        - review_reasons

        Allowed store keys:
        - store_name
        - store_address
        - store_phone_number

        Allowed purchase keys:
        - purchased_at_text

        Allowed payment keys:
        - payment_method

        Allowed items keys:
        - index
        - suggested_name
        - category
        - tax_rate
        - needs_review

        Allowed categories:
        #{allowed_categories.join(", ")}

        Allowed payment methods:
        #{allowed_payment_methods.join(", ")}

        For store:
        - store_name: prefer OCR store_name. Use filtered_content only when OCR is blank or clearly wrong.
        - store_address: prefer OCR store_address. Use address_candidates and filtered_content as supporting evidence.
        - store_address must be a physical address (for example, location/address text such as prefecture, city, street, or place information).
        - Do NOT use phone numbers, fax numbers, or other contact information as store_address.
        - If no clear physical address is supported, return null instead of filling store_address with contact text.
        - When multiple address candidates exist, prioritize the address that is clearly supported by filtered_content and store/branch context.
        - If filtered_content, address_candidates, and branch/store context consistently support a single store-level address, select that address and do NOT mark it as uncertain.
        - If the primary OCR store_address appears to be a headquarters or customer support address but a store-level address is supported elsewhere, prefer the store-level address.
        - Only mark store_address_uncertain when multiple plausible store-level addresses remain unresolved.
        - store_phone_number: prefer OCR store_phone_number. Do not invent phone numbers.
        - If OCR store_phone_number is present and plausibly formatted as a phone number, do not return null unless there is strong evidence that it is not a store phone number.
        - If a plausible phone number exists but you are not fully confident it is the correct store phone number, keep the plausible value and treat it as uncertain rather than missing.
        - Treat customer support or headquarters phone numbers as lower priority than numbers clearly tied to the store/branch context, but do not mark the phone number as missing when a plausible receipt phone number is present.
        - branch_name_candidates are supporting clues only. Do not return branch_name_candidates in the output.
        - Avoid headquarters or customer support addresses when selecting store_address.

        For purchase:
        - purchased_at_text: prefer OCR purchased_at_text, but when OCR only has the date and there is a clearly supported time candidate, return a time-inclusive purchased_at_text.
        - Use purchased_at_candidates, purchase_context_lines, and filtered_content as supporting evidence.
        - Prefer a full datetime candidate when the same date and time are clearly supported together.
        - Prefer receipt/transaction/payment context over order/preparation/reference context.
        - Treat lines mentioning order time, reservation time, or non-payment workflow timestamps as lower priority unless they are the only plausible transaction time.
        - If there is a single clearly supported transaction time, return purchased_at_text with both date and time.
        - If only the date is clearly supported and the time is genuinely uncertain, return the date only.
        - If multiple plausible transaction times conflict and cannot be resolved, return null and include purchased_at_conflicted in review_reasons.
        - If the purchase date/time cannot be determined at all, return null and include purchased_at_missing or purchased_at_uncertain as appropriate.
        - Do NOT invent timestamps.

        For payment:
        - payment_method: prefer OCR payment_method.
        - If OCR payment_method is blank, use payment_method_text, payment_candidates, payment_context_lines, and filtered_content.
        - Choose only from the allowed payment methods.
        - Use the following mapping examples as strong reference clues:
          - cash: 現金
          - credit_card: VISA, MasterCard, JCB, AMEX
          - e_money: QUICPay, iD, WAON, nanaco, 楽天Edy, 交通系IC (Suica, PASMO, ICOCA)
          - qr_payment: PayPay, 楽天ペイ, d払い, au PAY, メルペイ
          - debit_card: デビットカード
        - If a known payment brand appears, prioritize the correct category mapping over broad guessing from words like "Pay".
        - Do not confuse point/member/loyalty text with payment methods.

        For items:
        - Each returned item MUST correspond to an input item by index.
        - Do not add or remove item indexes.
        #{user_item_name_rules}
        - category: choose only from the allowed categories.
        - tax_rate: return the item's consumption tax rate only when it can be determined from tax.tax_details, tax.tax_context_lines, item raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content.
        - tax_rate MUST be a decimal rate such as 0.01 or 0.1. Do NOT return percentage strings such as "1%" or "10%".
        - When the receipt has multiple tax rates, assign tax_rate to each item whenever supported by the receipt context.
        - When the receipt has a single clear tax rate, return that same tax_rate for each item.
        - When an item's tax rate cannot be determined, return null for tax_rate and set needs_review = true.
        - needs_review: set true when the item name, category, or tax_rate remains uncertain.
        - Do not change price, quantity, quantity_unit, line_total, product_code, or confidence. Those are reference-only inputs and must not be returned.

        review_reasons rules:
        - Return an array of codes.
        - Use ONLY the following allowed codes (snake_case):
          #{allowed_review_reasons.join(",\n          ")}
        - Do NOT invent new codes.
        - Use store_phone_number_missing only when no plausible store phone number is supported by OCR candidates or filtered_content.
        - If a plausible store phone number exists but confidence is limited, use store_phone_number_uncertain instead of store_phone_number_missing.
        - Do NOT use combined or ambiguous codes such as "*_or_*".
        - If multiple reasons apply, include multiple entries (e.g., ["item_name_uncertain", "item_category_uncertain"]).
        - Include reasons only when review is needed.
        - Use item_tax_rate_uncertain when one or more item tax rates cannot be determined with confidence.
        - Use purchased_at_conflicted only when multiple plausible purchase timestamps remain unresolved after applying the purchase rules above.
        - Do NOT return store_phone_number_missing when store.store_phone_number is non-null.
        - Return [] when no review is needed.

        Input JSON:
        #{JSON.pretty_generate(input.to_h)}
      PROMPT
    end

    def ai_name_completion_enabled?
      input.dig(:meta, :ai_name_completion_enabled) == true
    end

    def system_item_name_rule
      if ai_name_completion_enabled?
        "- invent unrelated item names that are not semantically close to the OCR item text"
      else
        "- invent item names"
      end
    end

    def user_item_name_rules
      if ai_name_completion_enabled?
        <<~RULES.chomp
          - suggested_name: infer and improve item names that appear truncated or contain noise.
          - When correcting or completing item names, preserve and follow the original writing style (e.g., katakana, kanji, casing).
          - If an item name appears unusual, branded, or creatively styled, keep it as-is.
          - Do NOT correct or complete item names that are unusual, branded, or non-standard (e.g., unique or creative naming).
          - Only correct or complete item names when truncation or typographical errors are obvious and the completion is highly likely based on contextual or linguistic patterns.
          - If a completion is strongly suggested (even if not fully certain), you MAY complete it to a natural and commonly used product name while remaining semantically close to the original text.
          - If multiple possible completions exist, do not guess and keep the original OCR text.
          - Even when completion confidence is not high, keep needs_review = true.
        RULES
      else
        <<~RULES.chomp
          - suggested_name: improve truncated or noisy OCR item names only when clearly supported by raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content.
        RULES
      end
    end

    def allowed_categories
      %w[
        food
        drink
        daily_goods
        household
        medical
        beauty
        transportation
        hobby
        other
      ]
    end

    def allowed_payment_methods
      %w[
        cash
        credit_card
        e_money
        qr_payment
        debit_card
        other
      ]
    end

    def allowed_review_reasons
      %w[
        store_name_missing
        store_name_uncertain
        store_address_missing
        store_address_uncertain
        store_phone_number_missing
        store_phone_number_uncertain
        purchased_at_missing
        purchased_at_uncertain
        purchased_at_conflicted
        payment_method_missing
        payment_method_uncertain
        items_missing
        item_name_uncertain
        item_category_uncertain
        item_tax_rate_uncertain
      ]
    end
  end
end
