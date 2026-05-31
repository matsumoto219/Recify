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
        Output JSON data for a receipt processing system.
        You MUST output only a valid JSON object and follow all rules exactly.
        Do NOT include data that is not explicitly requested.

        All datetime values MUST follow these rules without exception:

        - Use ISO-like format: YYYY-MM-DD HH:MM
        - Time MUST be in 24-hour format (HH:MM)
        - Use only standard separators for date and time ("-" for date, ":" for time)

        Do NOT output anything except JSON.
        Do NOT include markdown fences or explanations.

        Use OCR candidates as the first reference, full_context_lines as raw OCR line context, and filtered_content as reduced supporting reference.

        You MUST NOT:
        - fabricate store names, addresses, phone numbers, timestamps, or payment methods
        #{system_item_name_rule}
        - change item names except where the item-name rules explicitly allow OCR-based correction or completion
        - change or guess numeric values such as totals, tax amounts, quantities, or prices
        - add fields not explicitly allowed

        If information is missing or uncertain:
        - return null
        - set needs_review = true

        When correcting values:
        - prioritize correctness over completeness
        - if a field cannot be determined with high confidence, return null or keep the original OCR text instead of guessing

        Output invariants:

        For item outputs:
        - Every returned item MUST map to an input item by index.
        - Do NOT add or remove item indexes.
        - price, quantity, quantity_unit, line_total, product_code, and confidence are reference-only inputs. Do NOT output or change them.

        For receipt_adjustments outputs:
        - amount MUST be an unsigned absolute integer.
        - Use sign to express whether the adjustment is a discount or surcharge.
        - source_text and source_line_index MUST refer to full_context_lines.
        - Do NOT output an adjustment if its amount cannot be tied to OCR text.

        For review_reasons:
        - Use only allowed review reason codes.
        - Do NOT combine codes.
        - Return [] when no review is needed.

        For non-receipts:
        - When is_receipt = false, still return store = {}, purchase = {}, payment = {}, items = [], receipt_adjustments = [], needs_review = false, and review_reasons = [].

        Do NOT output any schema other than the specified schema.

        Output schema constraints (STRICT):

        Top-level keys are exactly these:
        - is_receipt
        - is_receipt_confidence
        - document_type
        - rejection_reason
        - store
        - purchase
        - payment
        - items
        - receipt_adjustments
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

        Allowed receipt_adjustments keys:
        - kind
        - label
        - amount
        - sign
        - tax_rate
        - source_text
        - source_line_index
        - confidence
        - needs_review
        - review_reasons

        Allowed enum values:

        categories:
        #{allowed_categories.join(", ")}

        payment_methods:
        #{allowed_payment_methods.join(", ")}

        adjustment_kinds:
        #{allowed_adjustment_kinds.join(", ")}

        adjustment_signs:
        #{allowed_adjustment_signs.join(", ")}

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
        - Before completing OCR candidate values, decide whether the Input JSON represents a receipt.
        - Product lists, memos, articles, advertisements, and screenshots without checkout or payment context are not receipts.
        - If the document is clearly not a receipt, set is_receipt = false.
        - is_receipt_confidence MUST be a number between 0.0 and 1.0 when returned. 0.0 is the lowest confidence and 1.0 is the highest confidence.
        - When is_receipt = false, return document_type and an allowed rejection_reason value if they can be identified; otherwise return null.
        - For non-receipts, follow the system-defined empty output shape.
        - If uncertain, do not set is_receipt = false. Set needs_review = true and use low-to-medium is_receipt_confidence.

        For store information:
        - store_name: prefer OCR store_name. Only when it is blank or clearly wrong, use store_candidates, filtered_content, and full_context_lines as supporting evidence.
        - Use the store brand name as the core store_name. Combine branch names, shopping facility names, or regional/location names only when they are clearly connected to the store and produce a natural store_name.
        - Do NOT use descriptive phrases, slogans, business descriptions, addresses, phone numbers, fax numbers, register numbers, timestamps, receipt labels, or payment text as store_name.
        - Use meta.country_region as a reference for natural local store-name notation. Do NOT normalize to a different brand name unless OCR candidates and context support it.
        - If the store brand notation is unnatural for country_region and a common local notation is clearly supported, normalize it to that common local notation.
        - store_address: prefer OCR store_address. If it is blank or appears to be a headquarters or customer support address, look for a store-level address in address_candidates, filtered_content, and full_context_lines.
        - store_address MUST be a physical address only. Do NOT fill it with phone numbers, fax numbers, contact information, or URLs.
        - If one store-level address is clearly supported, return it. If multiple plausible store-level addresses remain unresolved, set store_address_uncertain. If no clear physical address exists, return null.
        - store_phone_number: prefer OCR store_phone_number. Do NOT invent phone numbers.
        - If a plausible phone number exists, keep it unless there is strong evidence that it is not a store phone number. If uncertain, use store_phone_number_uncertain instead of treating it as missing.
        - Prefer phone numbers clearly tied to the store or branch context over headquarters or customer support numbers.
        - store_candidates, branch_name_candidates, and address_candidates are supporting references only. Do NOT output those arrays.

        For purchase:
        - purchased_at_text: prefer OCR purchased_at_text. Do NOT invent timestamps.
        - If OCR contains only a date and purchased_at_candidates or purchase_context_lines contain a clearly supported transaction time, complete it to a datetime.
        - Use purchased_at_candidates, purchase_context_lines, and filtered_content as supporting evidence.
        - Prefer receipt, transaction, and payment context over order, preparation, reservation, or reference workflow times.
        - Use meta.country_region as a reference for local date and time notation.
        - Ignore unrelated numbers such as register numbers, order numbers, staff numbers, or reference numbers. Extract only the time expression.
        - If only the date is clearly supported and the time is uncertain, return the date only.
        - If multiple plausible transaction datetimes cannot be resolved, return null and include purchased_at_conflicted.
        - If the purchase date/time cannot be determined, return null and include purchased_at_missing or purchased_at_uncertain as appropriate.
        - Do NOT invent timestamps.

        For payment:
        - payment_method: prefer OCR payment_method.
        - If OCR payment_method is blank, use payment_method_text, payment_candidates, payment_context_lines, and filtered_content as supporting evidence.
        - Always choose from the allowed payment_methods.
        - Use meta.country_region as a reference for local payment brands and payment terminology.
        - Classify payment evidence by payment_method category, not by literal wording alone.

        Payment classification rules:
        - cash: expressions indicating cash, amount received, change, or cash payment.
        - credit_card: credit card brands, credit card slips, or card payment text. Treat VISA, MasterCard, American Express, and similar brands as credit_card unless debit is explicitly indicated.
        - debit_card: debit card brands or card payment text explicitly indicating debit.
        - e_money: transit IC cards, prepaid electronic money, or non-QR electronic wallets.
        - qr_payment: QR code, barcode, or mobile code payments.
        - other: payment evidence exists but cannot be classified above.

        - If a known local payment brand appears, use country_region and payment_context_lines to classify it.
        - Do NOT treat brand names in points, membership, coupons, loyalty programs, or advertising context as payment methods.
        - Do NOT infer a payment method from generic words such as "Pay", "Card", "Point", or "Member" without payment context.

        For items:
        - Preserve input item indexes.
        - category: choose only from the allowed categories.
        - Do not output reference-only numeric fields.
        #{user_item_name_rules}
        - tax_rate: return the item's consumption tax rate only when it can be determined from tax.tax_details, tax.tax_context_lines, item raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content.
        - Use country_region in meta as a reference for local tax rules when determining item tax_rate.
        - Do not assume tax rules for a specific country or region when country_region is missing or unclear.
        - tax_rate MUST be a decimal rate such as 0.01 or 0.1. Do NOT return percentage strings such as "1%" or "10%".
        - tax_rate_confidence MUST be a decimal between 0.0 and 1.0 when returned.
        - tax_rate_reason MUST be selected from the allowed tax rate reasons when returned.
        - tax_rate_reason SHOULD be one of: tax_detail_amount_match, printed_item_tax_marker, tax_summary_rate_match, standard_rate, reduced_rate, zero_or_exempt_candidate, tax_rate_not_visible, country_rule_uncertain, receipt_context_uncertain, ambiguous_tax_rate.
        - tax_rate_confidence and tax_rate_reason may be returned even when tax_rate is null.
        - Do NOT force uncertain tax rates into common local rates. Use tax_rate = null and needs_review = true when uncertain.
        - Set needs_review = true when the item name, category, or tax_rate remains uncertain.

        - Priority for item/adjustment tax_rate evidence is:
          1. tax.tax_details target/net amount and tax amount that uniquely match the item's line_total or a receipt_adjustment amount.
          2. explicit printed tax rate or tax marker on the item/adjustment line.
          3. footnotes, generic notes, or item-name inference.
        - In multi-rate receipts, first match each tax.tax_details target/net amount to exactly one item line_total or one taxable receipt_adjustment amount. If there is a unique amount match, use that tax detail's rate and set tax_rate_reason = tax_detail_amount_match.
        - If two or more items/adjustments share the same amount, do not guess from that amount match.
        - If the tax detail target amount is a sum of multiple items, do not guess from that amount match.
        - If the rate cannot be determined uniquely, use needs_review.
        - Printed VAT breakdowns, tax summaries, rate amount lines, reduced/standard rate summaries, and similar printed tax breakdowns are stronger evidence than item-name inference or generic notes.
        - Footnotes and symbols apply only to the item/adjustment they clearly mark. Do not spread a reduced-rate, VAT, tax-exempt, or generic footnote to every item.
        - Printed tax breakdowns take priority over generic tax notes.
        - If a printed tax breakdown shows the receipt total amount as a single tax-rate target, use that printed rate for all taxable items and taxable adjustments, even when a nearby note appears to mention a reduced tax rate.

        For receipt_adjustments:
        - Return receipt_adjustments when discount, coupon, point usage, return/refund, service charge, late-night charge, delivery fee, bag fee, handling fee, or a similar adjustment row exists.
        - Use full_context_lines to detect adjustments. Use filtered_content only as supporting evidence.
        - adjustment_candidates are OCR parser hints. Do NOT treat them as final facts.
        - If adjustment_candidates conflict with full_context_lines, tax details, totals, or item rows, prefer the full receipt context.
        - Do NOT rely only on known keywords. Use context, amounts, signs, neighboring lines, labels, and payment context to interpret Japanese, English, overseas, abbreviated, or unknown adjustment wording.
        - Treat point_usage as a payment adjustment. Do NOT treat point_usage as an item discount or tax adjustment.
        - adjustment_context_lines may exist for compatibility, but full_context_lines takes priority.
        - Labels and amounts may be split across neighboring OCR lines. Use previous_text and next_text to connect them.
        - Tie each adjustment amount to source_text, previous_text, or next_text.
        - Do NOT invent amount, label, percentage, or source_line_index.
        - Use sign according to whether the adjustment increases or decreases the total.
        - kind MUST be selected only from allowed adjustment_kinds.
        - If the row is clearly an adjustment but kind or sign is uncertain, use kind = other, set needs_review = true, and include adjustment_uncertain in review_reasons.

        review_reasons rules:
        - Use review reason codes to describe the concrete uncertainty.
        - If multiple reasons apply, include multiple entries.
        - Use store_phone_number_missing only when no plausible store phone number exists.
        - Use store_phone_number_uncertain when a plausible phone number exists but is uncertain.
        - Use item_tax_rate_uncertain when item tax_rate is uncertain.
        - Use purchased_at_conflicted when multiple purchase datetime candidates cannot be resolved.
        - Use ocr_unreadable when OCR is unreadable.
        - Use ocr_low_confidence when OCR quality is low.

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
          - When correcting or completing item names, preserve the original writing style, such as katakana, kanji, or casing.
          - Complete or correct item names only when the context supports the result with high confidence.
          - If multiple plausible completions exist, keep the original OCR text.
          - Even when completion confidence is not high, keep needs_review = true.
        RULES
      else
        <<~RULES.chomp
          - suggested_name: improve OCR item names with typos or noise only when clearly supported by raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content.
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

    def allowed_adjustment_kinds
      ReceiptAdjustment::KINDS
    end

    def allowed_adjustment_signs
      ReceiptAdjustment::SIGNS
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
        adjustment_uncertain
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
