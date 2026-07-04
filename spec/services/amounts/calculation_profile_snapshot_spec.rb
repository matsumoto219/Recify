require 'rails_helper'

RSpec.describe Amounts::CalculationProfileSnapshot do
  describe '.call' do
    it 'ReceiptAmountService resultから監査用の最小snapshotを作る' do
      result = {
        context: :analysis,
        rounding_mode: { tax: :floor, discount: :round },
        computed: {
          total: 1280,
          subtotal: 1164,
          tax: 116,
          items: [
            { raw_text: 'OCR全文を含む商品行', line_total: 1280 }
          ]
        },
        resolved: {
          total: 1280,
          subtotal: 1164,
          tax: 116,
          tax_rate: BigDecimal('0.1')
        },
        raw_ocr_text: '保存しないOCR全文',
        provider_raw_response: { endpoint: 'https://example.invalid/ocr', content: '保存しないprovider raw response' },
        store_metadata: { address: '保存しない店舗住所' },
        warning_reasons: [ :price_tax_inclusion_uncertain ],
        mismatch_codes: [ 'PRICE_TAX_INCLUSION_UNCERTAIN' ],
        blocking_mismatch_codes: [],
        warning_mismatch_codes: [ 'PRICE_TAX_INCLUSION_UNCERTAIN' ],
        calculation_profile: {
          tax_rounding_mode: :floor,
          discount_rounding_mode: :round,
          receipt_tax_basis: :total_includes_tax,
          item_amount_basis: :mixed_by_tax_rate_group,
          item_amount_basis_assignments: [
            {
              tax_rate: BigDecimal('0.1'),
              basis: :tax_included,
              net_amount: 1164,
              tax_amount: 116,
              gross_amount: 1280,
              raw_text: '保存しない'
            }
          ]
        },
        calculation_profile_score: 0,
        calculation_profile_candidates: [
          { profile: { item_amount_basis: :line_total_as_recorded }, score: 0 }
        ],
        ai_raw_response: { content: '保存しない' }
      }

      snapshot = described_class.call(result)

      aggregate_failures do
        expect(snapshot).to eq(
          schema_version: 1,
          profile: {
            tax_rounding_mode: 'floor',
            discount_rounding_mode: 'round',
            receipt_tax_basis: 'total_includes_tax',
            item_amount_basis: 'mixed_by_tax_rate_group',
            item_amount_basis_assignments: [
              {
                tax_rate: '0.1',
                basis: 'tax_included',
                net_amount: 1164,
                tax_amount: 116,
                gross_amount: 1280
              }
            ]
          },
          score: 0,
          warnings: [ 'price_tax_inclusion_uncertain' ],
          mismatch_codes: [ 'PRICE_TAX_INCLUSION_UNCERTAIN' ],
          blocking_mismatch_codes: [],
          warning_mismatch_codes: [ 'PRICE_TAX_INCLUSION_UNCERTAIN' ],
          context: 'analysis',
          rounding_mode: { 'tax' => 'floor', 'discount' => 'round' },
          computed: {
            total_amount: 1280,
            subtotal_amount: 1164,
            tax_amount: 116
          },
          resolved: {
            total_amount: 1280,
            subtotal_amount: 1164,
            tax_amount: 116
          }
        )
        expect(snapshot).not_to have_key(:calculation_profile_candidates)
        expect(snapshot.to_json).not_to include(
          'OCR全文を含む商品行',
          'ai_raw_response',
          'raw_ocr_text',
          'provider_raw_response',
          'endpoint',
          '保存しない',
          'provider raw response',
          'example.invalid',
          '店舗住所'
        )
      end
    end

    it 'profileがないmanual/edit_save結果でも空JSONにしない' do
      snapshot = described_class.call(
        {
          context: :manual,
          rounding_mode: { tax: :floor, discount: :round },
          computed: { total: 110, subtotal: 100, tax: 10 },
          resolved: { total: 110, subtotal: 100, tax: 10 },
          mismatch_codes: []
        }
      )

      aggregate_failures do
        expect(snapshot[:profile]).to be_nil
        expect(snapshot[:context]).to eq('manual')
        expect(snapshot.dig(:resolved, :total_amount)).to eq(110)
        expect(snapshot).not_to be_empty
      end
    end

    it 'amount_engineのselected candidate詳細をsnapshotに残す' do
      snapshot = described_class.call(
        {
          context: :analysis,
          computed: { total: 1_161, subtotal: 1_066, tax: 95 },
          resolved: { total: 1_161, subtotal: 1_066, tax: 95 },
          amount_engine: {
            schema_version: 1,
            selected_candidate_id: 'mixed_by_tax_rate_group/floor',
            selected_basis: 'mixed_by_tax_rate_group',
            selected_candidate: {
              candidate_id: 'mixed_by_tax_rate_group/floor',
              basis: 'mixed_by_tax_rate_group',
              subtotal: 1_066,
              tax: 95,
              purchase_total: 1_161,
              final_payment_total: 1_139,
              payment_adjustment_total: -22,
              payment_amount_sum: 1_139,
              score_breakdown: {
                receipt_total_delta: 0,
                raw_text: '保存しないscore raw text',
                metadata: { source_text: '保存しないscore nested source text' }
              },
              computed_items: [
                {
                  raw_text: '保存しない',
                  source_text: '保存しないsource text',
                  description: '保存しないdescription',
                  label: '保存しないcomputed item label',
                  price: 140,
                  quantity: BigDecimal('1'),
                  quantity_unit_code: 'each',
                  original_line_total: 130,
                  line_total: 140,
                  tax_rate: BigDecimal('0.08')
                }
              ],
              evidence: [
                { source: 'receipt_payments', payment_amount_sum: 1_139, final_payment_total: 1_139 },
                {
                  source: 'receipt_payments',
                  raw_text: '保存しない',
                  source_text: '保存しないsource text',
                  description: '保存しないdescription',
                  label: '保存しないlabel',
                  raw_label: '保存しないraw label',
                  payment_label: '保存しないpayment label',
                  adjustment_label: '保存しないadjustment label',
                  source_label: '保存しないsource label',
                  provider_raw_response: { endpoint: 'https://example.invalid/ocr', body: '保存しないprovider body' },
                  metadata: {
                    raw_text: '保存しないnested raw text',
                    store_metadata: { phone: '保存しない店舗電話' }
                  }
                }
              ]
            },
            candidates: []
          }
        }
      )

      aggregate_failures do
        # 検算: purchase_total 1,161 + payment_adjustment -22 = final_payment_total 1,139。
        expect(snapshot.dig(:amount_engine, :schema_version)).to eq(1)
        expect(snapshot.dig(:amount_engine, :selected_candidate)).to include(
          candidate_id: 'mixed_by_tax_rate_group/floor',
          basis: 'mixed_by_tax_rate_group',
          purchase_total: 1_161,
          final_payment_total: 1_139,
          payment_adjustment_total: -22,
          payment_amount_sum: 1_139
        )
        expect(snapshot.dig(:amount_engine, :selected_candidate, :score_breakdown)).to eq(
          'receipt_total_delta' => 0
        )
        expect(snapshot.dig(:amount_engine, :selected_candidate, :computed_items)).to eq([
          {
            'price' => 140,
            'quantity' => '1.0',
            'quantity_unit_code' => 'each',
            'original_line_total' => 130,
            'line_total' => 140,
            'tax_rate' => '0.08'
          }
        ])
        expect(snapshot.to_json).not_to include(
          '保存しない',
          'source text',
          'description',
          'raw_text',
          'source_text',
          'provider_raw_response',
          'label',
          'endpoint',
          'provider body',
          'example.invalid',
          '店舗電話'
        )
      end
    end

    it 'Amount Engine候補snapshot件数設定で制限済みの候補一覧を保持する' do
      create(
        :system_setting,
        key: Amounts::CandidateSnapshot::SETTING_KEY,
        value: SystemSettings.stored_value(1)
      )
      result = ReceiptAmountService.call(
        receipt: { total_amount: 100 },
        receipt_items: [
          { line_total: 100, tax_rate: BigDecimal('0') }
        ],
        receipt_tax_details: [],
        context: :analysis
      )

      snapshot = described_class.call(result)

      aggregate_failures do
        expect(snapshot[:schema_version]).to eq(1)
        expect(snapshot.dig(:amount_engine, :schema_version)).to eq(1)
        expect(result.dig(:amount_engine, :candidates).size).to eq(1)
        expect(snapshot.dig(:amount_engine, :selected_candidate)).to be_present
        expect(snapshot.dig(:amount_engine, :candidates).size).to eq(1)
        expect(snapshot.dig(:amount_engine, :candidates, 0, :candidate_id)).to eq(
          snapshot.dig(:amount_engine, :selected_candidate_id)
        )
        expect(snapshot.dig(:resolved, :total_amount)).to eq(100)
      end
    end
  end

  describe 'receipts.amount_calculation_profile schema' do
    it 'jsonb default {} null falseで定義されている' do
      column = Receipt.columns_hash.fetch('amount_calculation_profile')
      receipt = create(:receipt)

      aggregate_failures do
        expect(column.type).to eq(:jsonb)
        expect(column.null).to eq(false)
        expect(column.default).to eq('{}')
        expect(receipt.amount_calculation_profile).to eq({})
      end
    end
  end
end
