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

        All datetime values MUST be returned in a parser-friendly format.

        - Use ISO-like format: YYYY-MM-DD HH:MM
        - Time MUST be in 24-hour format (HH:MM)
        - Do NOT include locale-specific words, characters, or formatting styles
        - Do NOT include month names, AM/PM markers, or localized time suffixes
        - Use only numeric date and time with standard separators ("-" for date, ":" for time)

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

        Output schema constraints (STRICT):

        Top-level keys (exactly these):
        - is_receipt
        - is_receipt_confidence
        - document_type
        - rejection_reason
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
        - tax_rate_confidence
        - tax_rate_reason
        - needs_review

        Allowed enum values:

        categories:
        #{allowed_categories.join(", ")}

        payment_methods:
        #{allowed_payment_methods.join(", ")}

        review_reasons:
        #{allowed_review_reasons.join(", ")}

        Allowed rejection_reason values:
        #{allowed_rejection_reasons.join(", ")}

        You MUST NOT output keys or enum values outside of the above definitions.
      PROMPT
    end

    def user_prompt
      <<~PROMPT
        For document classification:
        - First decide whether the document can be treated as a receipt, invoice, or purchase proof.
        - Prioritize document-type classification before completing OCR candidate values.
        - Advertisements, development notes, general documents, text-only memos, and product lists without checkout/payment context are not receipts.
        - If the document is clearly not a receipt, invoice, or purchase proof, set is_receipt = false.
        - is_receipt_confidence MUST be a number between 0.0 and 1.0 when returned.
        - Higher confidence means closer to 1.0.
        - Use is_receipt = false only when confidence is high.
        - When is_receipt = false, return document_type and rejection_reason when they can be stated briefly; otherwise return null.
        - When is_receipt = false, rejection_reason MUST be one of the allowed rejection_reason values.
        - Do NOT output free-form rejection_reason values outside the allowed list.
        - When is_receipt = false, still return store = {}, purchase = {}, payment = {}, items = [], needs_review = false, and review_reasons = [].
        - If uncertain, do not set is_receipt to false; set is_receipt = true and needs_review = true.
        - If uncertain, keep is_receipt = true, set needs_review = true, and use low-to-medium is_receipt_confidence.

        For store:
        - store_name: prefer OCR store_name. Use filtered_content only when OCR is blank or clearly wrong.
        - If store_candidates are present, choose the most appropriate store_name from store_candidates and supporting filtered_content.
        - Prefer the store brand name as the core store_name.
        - If a branch name, shopping facility name, or regional/location name clearly appears to be connected to the store, you SHOULD combine it with the brand name when doing so results in a more complete and natural store_name.
        - Prefer a store_name that uniquely identifies the specific store location over a generic brand-only name when both are supported.
        - Do NOT choose descriptive phrases, slogans, business descriptions, addresses, phone numbers, fax numbers, register numbers, timestamps, receipt labels, or payment text as store_name.
        - Use country_region in meta only as a reference for natural store-name notation in that country or region.
        - When a store brand is written in a notation that is clearly unnatural for the country_region but clearly maps to a common local notation, you MAY normalize it to that common local notation.
        - When spacing, casing, punctuation, or separators are unnatural or unnecessary for the country_region, you MAY normalize them only if the brand remains clearly identifiable.
        - Do NOT normalize names when the mapping is uncertain, when multiple brands could match, or when the normalized name is not directly supported by store_candidates, OCR candidates, or filtered_content.
        - Do NOT invent a different store brand that is not supported by store_candidates, OCR candidates, or filtered_content.
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
        - store_candidates and branch_name_candidates are supporting clues only. Do not return store_candidates or branch_name_candidates in the output.
        - Avoid headquarters or customer support addresses when selecting store_address.

        For purchase:
        - purchased_at_text: prefer OCR purchased_at_text, but when OCR only has the date and there is a clearly supported time candidate, return a time-inclusive purchased_at_text.
        - Use purchased_at_candidates, purchase_context_lines, and filtered_content as supporting evidence.
        - Prefer a full datetime candidate when the same date and time are clearly supported together.
        - Prefer receipt/transaction/payment context over order/preparation/reference context.
        - Treat lines mentioning order time, reservation time, or non-payment workflow timestamps as lower priority unless they are the only plausible transaction time.
        - If there is a single clearly supported transaction time, return purchased_at_text with both date and time.
        - Use country_region in meta as a reference for recognizing natural date and time notation in that country or region.
        - If purchased_at_text contains only a date and purchased_at_candidates or purchase_context_lines contain a recognizable local time expression, combine the date with that time.
        - A time expression may appear after unrelated leading numbers such as register numbers, receipt numbers, order numbers, staff numbers, or reference numbers.
        - Ignore unrelated leading numbers before the recognizable time expression.
        - Extract only the transaction time expression; do not treat unrelated leading numbers as part of the time.
        - If only the date is clearly supported and the time is genuinely uncertain, return the date only.
        - If multiple plausible transaction times conflict and cannot be resolved, return null and include purchased_at_conflicted in review_reasons.
        - If the purchase date/time cannot be determined at all, return null and include purchased_at_missing or purchased_at_uncertain as appropriate.
        - Do NOT invent timestamps.

        For payment:
        - payment_method: prefer OCR payment_method.
        - If OCR payment_method is blank, use payment_method_text, payment_candidates, payment_context_lines, and filtered_content.
        - Choose only from the allowed payment methods.
        - Use country_region in meta as a reference for interpreting local payment terminology and locally common payment brands.
        - Map the detected payment evidence to one of the allowed payment methods by category, not by literal wording alone.
        - cash: physical cash payment, local words or abbreviations meaning cash, cash total, amount received, or change.
        - credit_card: international or local credit card brands, credit card transaction slips, or card payment text indicating credit.
        - e_money: stored-value electronic money, transit/transport IC cards, prepaid contactless cards, or local electronic wallet systems that are not primarily QR/code payments.
        - qr_payment: QR code, barcode, mobile code, or app-based scan payment services common in the country_region.
        - debit_card: debit card brands or card payment text clearly indicating debit.
        - other: supported payment evidence exists but does not fit the categories above.
        - International card brands such as VISA, MasterCard, American Express, and similar globally recognized card networks are strong clues for credit_card unless the receipt clearly indicates debit.
        - If a known local payment brand appears, use country_region and payment_context_lines to classify it into the correct allowed category.
        - Do not classify as a payment method from brand names alone when the surrounding context indicates points, membership, coupons, loyalty programs, rewards, or advertisements rather than payment.
        - Do not infer a payment method solely from generic words such as "Pay", "Card", "Point", or "Member" without payment context.

        For items:
        - Each returned item MUST correspond to an input item by index.
        - Do not add or remove item indexes.
        #{user_item_name_rules}
        - category: choose only from the allowed categories.
        - tax_rate: return the item's consumption tax rate only when it can be determined from tax.tax_details, tax.tax_context_lines, item raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content.
        - Use country_region in meta as a reference for local tax rules when determining item tax_rate.
        - Do not assume tax rules for a specific country or region when country_region is missing or unclear.
        - For items that may be non-taxable or zero-rated, determine tax_rate from receipt text, item name, raw_text, matched_content_lines, matched_filtered_content_lines, and nearby context.
        - Do not force uncertain item tax rates into common local rates such as 0.08 or 0.1.
        - tax_rate MUST be a decimal rate such as 0.01 or 0.1. Do NOT return percentage strings such as "1%" or "10%".
        - tax_rate_confidence MUST be a decimal between 0.0 and 1.0 when returned.
        - tax_rate_reason MUST be a short enum-like string when returned.
        - tax_rate_reason SHOULD be one of: standard_rate, reduced_rate, zero_or_exempt_candidate, tax_rate_not_visible, country_rule_uncertain, receipt_context_uncertain.
        - tax_rate_confidence and tax_rate_reason may be returned even when tax_rate is null.
        - When the receipt has multiple tax rates, assign tax_rate to each item whenever supported by the receipt context.
        - When the receipt has a single clear tax rate, return that same tax_rate for each item.
        - When tax_rate confidence is low, lower tax_rate_confidence instead of guessing.
        - When an item tax_rate cannot be selected safely, return null for tax_rate and set needs_review = true.
        - needs_review: set true when the item name, category, or tax_rate remains uncertain.
        - Do not change price, quantity, quantity_unit, line_total, product_code, or confidence. Those are reference-only inputs and must not be returned.

        review_reasons rules:
        - Return an array of codes.
        - Use ONLY allowed codes defined in the system constraints.
        - Do NOT invent new codes.
        - Use store_phone_number_missing only when no plausible store phone number is supported by OCR candidates or filtered_content.
        - If a plausible store phone number exists but confidence is limited, use store_phone_number_uncertain instead of store_phone_number_missing.
        - Do NOT use combined or ambiguous codes such as "*_or_*".
        - If multiple reasons apply, include multiple entries (e.g., ["item_name_uncertain", "item_category_uncertain"]).
        - Include reasons only when review is needed.
        - Use item_tax_rate_uncertain when one or more item tax rates cannot be determined with confidence.
        - Use purchased_at_conflicted only when multiple plausible purchase timestamps remain unresolved after applying the purchase rules above.
        - Use ocr_unreadable when OCR content is too sparse, broken, or unreadable to support reliable receipt analysis.
        - Use ocr_low_confidence when OCR content is present but confidence or text quality appears too low to trust without user confirmation.
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
        ocr_unreadable
        ocr_low_confidence
      ]
    end

    def allowed_rejection_reasons
      %w[
        no_text
        memo
        article
        screenshot
        presentation
        poster
        shopping_list
        menu
        code_snippet
        unknown_document
        other
      ]
    end
  end
end
