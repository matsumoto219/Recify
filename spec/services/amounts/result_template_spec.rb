require 'rails_helper'

RSpec.describe Amounts::ResultTemplate do
  def build_result(inconsistencies)
    described_class.build(
      computed: {},
      resolved: {},
      inconsistencies: inconsistencies,
      mismatch_codes: inconsistencies.filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency) }
    )
  end

  it 'does not need review for warning-only mismatches' do
    result = build_result([:ocr_total_mismatch])

    aggregate_failures do
      expect(result[:needs_review]).to be(false)
      expect(result[:warning_inconsistencies]).to eq([:ocr_total_mismatch])
      expect(result[:blocking_inconsistencies]).to be_empty
      expect(result[:warning_mismatch_codes]).to eq(['OCR_TOTAL_MISMATCH'])
      expect(result[:warning_reasons]).to eq(['ocr_total_mismatch'])
    end
  end

  it 'does not need review for tax_detail_rate_mismatch alone' do
    result = build_result([:tax_detail_rate_mismatch])

    aggregate_failures do
      expect(result[:needs_review]).to be(false)
      expect(result[:warning_inconsistencies]).to eq([:tax_detail_rate_mismatch])
      expect(result[:warning_mismatch_codes]).to eq(['TAX_DETAIL_RATE_MISMATCH'])
    end
  end

  it 'needs review when a blocking mismatch exists' do
    result = build_result([:ocr_total_mismatch, :tax_detail_mismatch])

    aggregate_failures do
      expect(result[:needs_review]).to be(true)
      expect(result[:warning_inconsistencies]).to eq([:ocr_total_mismatch])
      expect(result[:blocking_inconsistencies]).to eq([:tax_detail_mismatch])
      expect(result[:blocking_mismatch_codes]).to eq(['TAX_DETAIL_MISMATCH'])
    end
  end
end
