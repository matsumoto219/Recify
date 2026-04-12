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
            - invent values that are not present in the OCR input
            - invent store names, addresses, phone numbers, timestamps, payment methods, or item names
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
            - store_phone_number: prefer OCR store_phone_number. Do not invent phone numbers.
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
            - suggested_name: improve truncated or noisy OCR item names only when clearly supported by raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content.
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
            - If multiple reasons apply, include multiple entries (e.g., ["item_name_uncertain", "item_category_uncertain"]).
            - Include reasons only when review is needed.
            - Use purchased_at_conflicted only when multiple plausible purchase timestamps remain unresolved after applying the purchase rules above.
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
      end
    end
  end
end
