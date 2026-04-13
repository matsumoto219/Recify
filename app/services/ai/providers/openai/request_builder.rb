require "json"

module Ai
  module Providers
    module Openai
      class RequestBuilder
        DEFAULT_MODEL = "gpt-4.1-mini".freeze

        class << self
          def build(input)
            new(input).build
          end
        end

        def initialize(input)
          @input = input || {}
        end

        def build
          {
            model: model_name,
            input: [
              {
                role: "system",
                content: [
                  {
                    type: "input_text",
                    text: system_prompt
                  }
                ]
              },
              {
                role: "user",
                content: [
                  {
                    type: "input_text",
                    text: user_prompt
                  }
                ]
              }
            ],
            text: {
              format: {
                type: "json_object"
              }
            }
          }
        end

        private

        attr_reader :input

        def model_name
          ENV.fetch("OPENAI_AI_MODEL", DEFAULT_MODEL)
        end

        def system_prompt
          <<~PROMPT.strip
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

            Follow the schema strictly.
            Any deviation is considered a failure.
          PROMPT
        end

        def user_prompt
          <<~PROMPT
            Analyze the following OCR-derived receipt data and return a JSON object.

            All required top-level keys MUST be present.
            If a value is unknown, use null.
            Do not omit keys.

            Return strictly the following JSON structure:

            Required top-level keys:
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
            - needs_review

            Allowed categories:
            #{allowed_categories.join(", ")}

            Allowed payment methods:
            #{allowed_payment_methods.join(", ")}

            Decision rules:
            - Prefer OCR candidates when they are plausible.
            - Use filtered_content only as supporting evidence or to fill blank OCR fields.
            - Do not invent values that are not clearly supported by OCR candidates or filtered_content.

            For store:
            - store_name: prefer OCR store_name. Use filtered_content only when OCR is blank or clearly wrong.
            - store_address: prefer OCR store_address. Use address_candidates and filtered_content as supporting evidence.
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
            - Use payment_method_text, payment_candidates, payment_context_lines, and filtered_content as supporting evidence.
            - Do not treat point/member labels as payment methods.

            For items:
            - Each returned item MUST correspond to an input item by index.
            - Do not add or remove item indexes.
            #{user_item_name_rules}
            - category: choose only from the allowed categories.
            - needs_review: set true when the item name or category remains uncertain.
            - Do not change price, quantity, quantity_unit, line_total, product_code, or confidence. Those are reference-only inputs and must not be returned.

            review_reasons rules:
            - Return an array of codes.
            - Use ONLY the following allowed codes (snake_case):
              store_name_missing,
              store_name_uncertain,
              store_address_missing,
              store_address_uncertain,
              store_phone_number_missing,
              store_phone_number_uncertain,
              purchased_at_missing,
              purchased_at_uncertain,
              purchased_at_conflicted,
              payment_method_missing,
              payment_method_uncertain,
              items_missing,
              item_name_uncertain,
              item_category_uncertain
            - Do NOT invent new codes.
            - Do NOT use combined or ambiguous codes such as "*_or_*".
            - Use store_phone_number_missing only when no plausible store phone number is supported by OCR candidates or filtered_content.
            - If a plausible store phone number exists but confidence is limited, use store_phone_number_uncertain instead of store_phone_number_missing.
            - If multiple reasons apply, include multiple entries (e.g., ["item_name_uncertain", "item_category_uncertain"]).
            - Include reasons only when review is needed.
            - Use purchased_at_conflicted only when multiple plausible purchase timestamps remain unresolved after applying the purchase rules above.
            - Do NOT return store_phone_number_missing when store.store_phone_number is non-null.
            - Return [] when no review is needed.

            Input JSON:
            #{JSON.pretty_generate(input)}
          PROMPT
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

        def ai_name_completion_enabled?
          value = if input.respond_to?(:with_indifferent_access)
            input.with_indifferent_access.dig(:meta, :ai_name_completion_enabled)
          else
            nil
          end

          value == true
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
              - suggested_name: improve truncated, noisy, unnatural, or suspicious OCR item names when a plausible completion is suggested by raw_text, matched_content_lines, matched_filtered_content_lines, filtered_content, or common product naming patterns of the receipt language/locale.
              - If a product name appears partially valid but unnaturally truncated, you MAY complete it to the most plausible common retail product name as long as it remains semantically close to the original raw_text.
              - Prefer realistic completions that preserve the original raw_text semantics rather than copying unnatural fragments unchanged.
              - If you infer a completion that is not overwhelmingly certain, keep needs_review = true.
            RULES
          else
            <<~RULES.chomp
              - suggested_name: improve truncated or noisy OCR item names only when clearly supported by raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content.
            RULES
          end
        end
      end
    end
  end
end
