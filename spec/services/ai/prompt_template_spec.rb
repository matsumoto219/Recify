require 'rails_helper'

RSpec.describe Ai::PromptTemplate do
  describe '.build' do
    let(:input) do
      {
        meta: {
          country_region: 'JPN'
        },
        tax: {
          tax_details: [
            { rate: 0.1, amount: 45, net_amount: 455, description: '10%対象' }
          ],
          tax_context_lines: [
            '10%対象 455 45'
          ]
        },
        items: [
          {
            index: 0,
            raw_text: '50円切手',
            matched_content_lines: [ '50円切手 50' ],
            matched_filtered_content_lines: [ '50円切手 50' ]
          }
        ]
      }
    end

    let(:built_prompt) { described_class.build(input) }
    let(:system_prompt) { built_prompt[:system] }
    let(:user_prompt) { built_prompt[:user] }

    it 'country_region を item tax_rate 判断材料として使うよう指示する' do
      expect(user_prompt).to include(
        'Use country_region in meta as a reference for local tax rules when determining item tax_rate.'
      )
    end

    it 'country_region が不明な場合に特定国の税制を仮定しないよう指示する' do
      expect(user_prompt).to include(
        'Do not assume tax rules for a specific country or region when country_region is missing or unclear.'
      )
    end

    it 'item tax_rate は許可された入力根拠から判断するよう指示する' do
      expect(user_prompt).to include(
        "tax_rate: return the item's consumption tax rate only when it can be determined from tax.tax_details, tax.tax_context_lines, item raw_text, matched_content_lines, matched_filtered_content_lines, or filtered_content."
      )
    end

    it '確信が低い場合は confidence を低くし、tax_rate を安全に選べない場合は null と needs_review true にするよう指示する' do
      expect(user_prompt).to include(
        'tax_rate_confidence MUST be a decimal between 0.0 and 1.0 when returned.'
      )
      expect(user_prompt).to include(
        'Use tax_rate = null and needs_review = true when uncertain.'
      )
    end

    it '不確実な税率を一般的な税率へ無理に寄せないよう指示する' do
      expect(user_prompt).to include(
        'Do NOT force uncertain tax rates into common local rates.'
      )
    end

    it '印字された税率別内訳を注記より優先するよう指示する' do
      aggregate_failures do
        expect(user_prompt).to include('Printed tax breakdowns take priority over generic tax notes.')
        expect(user_prompt).to include('tax.tax_details target/net amount and tax amount that uniquely match')
        expect(user_prompt).to include('tax_rate_reason = tax_detail_amount_match')
        expect(user_prompt).to include('Footnotes and symbols apply only to the item/adjustment they clearly mark.')
        expect(user_prompt).to include('Printed VAT breakdowns, tax summaries')
        expect(user_prompt).to include('use that printed rate for all taxable items and taxable adjustments')
      end
    end

    it 'tax_rate_confidence と tax_rate_reason の返却ルールを指示する' do
      aggregate_failures do
        expect(user_prompt).to include('tax_rate_confidence MUST be a decimal between 0.0 and 1.0 when returned.')
        expect(user_prompt).to include('tax_rate_reason MUST be selected from the allowed tax rate reasons when returned.')
        expect(user_prompt).to include('tax_detail_amount_match, printed_item_tax_marker, tax_summary_rate_match')
        expect(user_prompt).to include('standard_rate, reduced_rate, zero_or_exempt_candidate, tax_rate_not_visible, country_rule_uncertain, receipt_context_uncertain, ambiguous_tax_rate')
        expect(user_prompt).to include('tax_rate_confidence and tax_rate_reason may be returned even when tax_rate is null.')
      end
    end

    it 'AI response parser / normalizer の item schema に tax_rate metadata を許可する' do
      aggregate_failures do
        expect(system_prompt).to include('- is_receipt')
        expect(system_prompt).to include('- is_receipt_confidence')
        expect(system_prompt).to include('- document_type')
        expect(system_prompt).to include('- rejection_reason')
        expect(system_prompt).to include('- tax_rate')
        expect(system_prompt).to include('- tax_rate_confidence')
        expect(system_prompt).to include('- tax_rate_reason')
        expect(system_prompt).to include('- needs_review')
        expect(Analysis.receipt_item_ai_allowed_keys).to eq(%i[
          index
          position_index
          suggested_name
          category
          needs_review
          tax_rate
          tax_rate_confidence
          tax_rate_reason
        ])
      end
    end

    it '商品名補完OFF時はOCR由来の商品名を絶対に編集しないよう指示する' do
      aggregate_failures do
        expect(user_prompt).to include('suggested_name: preserve the item name exactly as captured by OCR and do not edit it under any circumstances.')
        expect(user_prompt).not_to include('improve OCR item names with typos or noise only when clearly supported')
        expect(user_prompt).not_to include('infer or complete item names when they appear truncated, noisy, or misspelled')
      end
    end

    it '商品名補完ON時は商品名の補完・誤字修正だけを許可する' do
      prompt = described_class.build(
        input.deep_merge(meta: { ai_name_completion_enabled: true })
      )
      enabled_user_prompt = prompt[:user]

      aggregate_failures do
        expect(enabled_user_prompt).to include('suggested_name: infer or complete item names when they appear truncated, noisy, or misspelled.')
        expect(enabled_user_prompt).to include('When completing or correcting item names, preserve the original writing style, such as katakana, kanji, or uppercase/lowercase English.')
        expect(enabled_user_prompt).to include('Do NOT change an item into a different product by guesswork.')
        expect(enabled_user_prompt).to include('Complete or correct item names only when confidence is sufficiently high.')
        expect(enabled_user_prompt).to include('Keep needs_review = true when the completed result is not sufficiently confident.')
        expect(enabled_user_prompt).not_to include('preserve the item name exactly as captured by OCR and do not edit it under any circumstances.')
      end
    end

    it 'レシートではない画像の判定ルールを指示する' do
      aggregate_failures do
        expect(user_prompt).to include('Before completing OCR candidate values, decide whether the Input JSON represents a receipt.')
        expect(user_prompt).to include('Product lists, memos, articles, advertisements, and screenshots without checkout or payment context are not receipts.')
        expect(user_prompt).to include('If uncertain, do not set is_receipt = false. Set needs_review = true and use low-to-medium is_receipt_confidence.')
      end
    end

    it '店舗名と運営主体・法的主体を区別するよう指示する' do
      store_information_prompt = user_prompt.split("For store information:", 2).last.split("For purchase:", 2).first

      aggregate_failures do
        expect(user_prompt).to include('customer-facing store, venue, facility')
        expect(user_prompt).to include('operator, management company, contractor, franchisee, licensee')
        expect(user_prompt).to include('Legal entity designators, company suffixes, or jurisdiction-specific corporate forms')
        expect(user_prompt).to include('management, operation, ownership, contracting, licensing, facility administration')
        expect(user_prompt).to include('preserve that printed combined name as store_name')
        expect(user_prompt).to include('isolated leading character, symbol, or logo fragment')
        expect(user_prompt).to include('prefer the clean customer-facing name')
        expect(user_prompt).to include('Do NOT add unprinted branch suffixes, store-type suffixes, location suffixes')
        expect(user_prompt).to include('operator_candidates')
        expect(store_information_prompt).not_to include('common local notation')
        expect(store_information_prompt).not_to match(/[一-龠ぁ-んァ-ヶ]/)
      end
    end

    it 'not receipt の rejection_reason 許可リストを指示する' do
      aggregate_failures do
        expect(system_prompt).to include('Allowed rejection_reason values:')
        expect(system_prompt).to include('no_text, memo, article, screenshot, presentation, poster, shopping_list, menu, code_snippet, unknown_document, other')
        expect(user_prompt).to include('When is_receipt = false, return document_type and an allowed rejection_reason value if they can be identified; otherwise return null.')
      end
    end

    it 'is_receipt_confidence の返却ルールを指示する' do
      aggregate_failures do
        expect(user_prompt).to include('is_receipt_confidence MUST be a number between 0.0 and 1.0 when returned. 0.0 is the lowest confidence and 1.0 is the highest confidence.')
        expect(user_prompt).to include('If uncertain, do not set is_receipt = false. Set needs_review = true and use low-to-medium is_receipt_confidence.')
      end
    end

    it '特殊加減算はfull_context_lines全体から検出するよう指示する' do
      aggregate_failures do
        expect(system_prompt).to include('full_context_lines as raw OCR line context')
        expect(user_prompt).to include('Use full_context_lines to detect adjustments.')
        expect(user_prompt).to include('Do NOT rely only on known keywords.')
        expect(user_prompt).to include('full_context_lines takes priority.')
        expect(user_prompt).to include('overseas, abbreviated, or unknown adjustment wording.')
        expect(user_prompt).to include('Labels and amounts may be split across neighboring OCR lines.')
        expect(user_prompt).to include('Tie each adjustment amount to source_text, previous_text, or next_text.')
        expect(user_prompt).to include('Treat point_usage as a payment adjustment. Do NOT treat point_usage as an item discount or tax adjustment.')
        expect(user_prompt).to include('Use sign according to whether the adjustment increases or decreases the total.')
        expect(system_prompt).not_to include('item_discount')
        expect(user_prompt).not_to include('item_discount')
      end
    end

    it '出力不変条件をsystem promptで指示する' do
      aggregate_failures do
        expect(system_prompt).to include('Output invariants:')
        expect(system_prompt).to include('Every returned item MUST map to an input item by index.')
        expect(system_prompt).to include('Do NOT add or remove item indexes.')
        expect(system_prompt).to include('price, quantity, quantity_unit, line_total, product_code, and confidence are reference-only inputs. Do NOT output or change them.')
        expect(system_prompt).to include('amount MUST be an unsigned absolute integer.')
        expect(system_prompt).to include('source_text and source_line_index MUST refer to full_context_lines.')
        expect(system_prompt).to include('Do NOT output an adjustment if its amount cannot be tied to OCR text.')
        expect(system_prompt).to include('Use only allowed review reason codes.')
        expect(system_prompt).to include('Do NOT combine codes.')
        expect(system_prompt).to include('When is_receipt = false, still return store = {}, purchase = {}, payment = {}, items = [], receipt_adjustments = [], needs_review = false, and review_reasons = [].')
        expect(user_prompt).to include('For non-receipts, follow the system-defined empty output shape.')
      end
    end
  end
end
