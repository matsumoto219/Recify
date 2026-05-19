require 'rails_helper'

RSpec.describe Analysis::ReceiptSignalEvaluator do
  def evaluate(overrides = {})
    described_class.call(base_ocr_result.deep_merge(overrides))
  end

  def fixture_result(name)
    JSON.parse(Rails.root.join("spec/fixtures/ocr/#{name}.json").read).deep_symbolize_keys
  end

  let(:base_ocr_result) do
    {
      success: true,
      raw_text: 'メモ',
      lines: [ 'メモ' ],
      candidates: {
        store_name: nil,
        store_address: nil,
        store_phone_number: nil,
        purchased_at_text: nil,
        total_amount: nil,
        payment_method_text: nil,
        country_region: nil,
        receipt_type: nil,
        items: [],
        payments: [],
        tax_details: []
      },
      meta: {
        doc_type: nil
      }
    }
  end

  it 'total_amount単独で通過する' do
    result = evaluate(
      raw_text: '合計 1280',
      lines: [ '合計 1280' ],
      candidates: { total_amount: 1280 }
    )

    aggregate_failures do
      expect(result.text_present).to eq(true)
      expect(result.score).to be >= 5
      expect(result.reasons).to include(:total_amount)
      expect(result.strong_signal).to eq(true)
      expect(result.receipt_like?).to eq(true)
    end
  end

  it 'valid items単独で通過する' do
    result = evaluate(
      raw_text: 'コーヒー 180',
      lines: [ 'コーヒー 180' ],
      candidates: {
        items: [
          { raw_text: 'コーヒー', line_total: 180 }
        ]
      }
    )

    aggregate_failures do
      expect(result.score).to be >= 5
      expect(result.reasons).to include(:valid_items)
      expect(result.strong_signal).to eq(true)
      expect(result.receipt_like?).to eq(true)
    end
  end

  it 'CountryRegionとReceiptTypeだけでは遮断する' do
    result = evaluate(
      raw_text: '旅行メモ',
      lines: [ '旅行メモ' ],
      candidates: {
        country_region: 'JP',
        receipt_type: 'Meal'
      }
    )

    aggregate_failures do
      expect(result.score).to eq(0)
      expect(result.reasons).not_to include(:country_region, :receipt_type)
      expect(result.receipt_like?).to eq(false)
    end
  end

  it 'docType receipt.* だけでは遮断する' do
    result = evaluate(
      raw_text: '開発メモ',
      lines: [ '開発メモ' ],
      meta: { doc_type: 'receipt.retailMeal' }
    )

    aggregate_failures do
      expect(result.score).to eq(1)
      expect(result.reasons).to include(:doc_type_receipt)
      expect(result.strong_signal).to eq(false)
      expect(result.receipt_like?).to eq(false)
    end
  end

  it 'purchased_at_textだけでは遮断する' do
    result = evaluate(
      raw_text: '2026/04/02 12:34',
      lines: [ '2026/04/02 12:34' ],
      candidates: { purchased_at_text: '2026/04/02 12:34' }
    )

    aggregate_failures do
      expect(result.score).to eq(1)
      expect(result.reasons).to include(:purchased_at)
      expect(result.receipt_like?).to eq(false)
    end
  end

  it 'payment_method_textだけでは遮断する' do
    result = evaluate(
      raw_text: 'VISA',
      lines: [ 'VISA' ],
      candidates: { payment_method_text: 'VISA' }
    )

    aggregate_failures do
      expect(result.score).to eq(1)
      expect(result.reasons).to include(:payment_method_text)
      expect(result.receipt_like?).to eq(false)
    end
  end

  it 'receipt語と金額行があれば通過する' do
    result = evaluate(
      raw_text: "領収書\n合計 1280",
      lines: [ '領収書', '合計 1280' ]
    )

    aggregate_failures do
      expect(result.reasons).to include(:receipt_word, :receipt_amount_context_line)
      expect(result.strong_signal).to eq(true)
      expect(result.receipt_like?).to eq(true)
    end
  end

  it '商品金額行2件とdateがあれば通過する' do
    result = evaluate(
      raw_text: "2026/04/02\nコーヒー 180\nサンド 550",
      lines: [ '2026/04/02', 'コーヒー 180', 'サンド 550' ]
    )

    aggregate_failures do
      expect(result.reasons).to include(:date_time_pattern, :money_like_item_lines)
      expect(result.receipt_like?).to eq(true)
    end
  end

  it '商品金額行だけでは遮断する' do
    result = evaluate(
      raw_text: "コーヒー 180\nサンド 550",
      lines: [ 'コーヒー 180', 'サンド 550' ]
    )

    aggregate_failures do
      expect(result.reasons).to include(:money_like_item_lines)
      expect(result.receipt_like?).to eq(false)
    end
  end

  it '空OCR fixtureはno_text_detected相当として扱う' do
    result = described_class.call(fixture_result('non_receipt_empty'))

    aggregate_failures do
      expect(result.text_present).to eq(false)
      expect(result.score).to eq(0)
      expect(result.receipt_like?).to eq(false)
    end
  end

  it 'docType receipt.* の開発メモfixtureはreceipt_not_detected相当として扱う' do
    result = described_class.call(fixture_result('non_receipt_doc_type_memo'))

    aggregate_failures do
      expect(result.text_present).to eq(true)
      expect(result.reasons).to include(:doc_type_receipt)
      expect(result.receipt_like?).to eq(false)
    end
  end
end
