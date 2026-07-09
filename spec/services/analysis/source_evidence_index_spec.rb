require 'rails_helper'

RSpec.describe Analysis::SourceEvidenceIndex do
  it 'OCR行とtoken spanをline index付きで保持する' do
    result = described_class.call(
      lines: [ 'レジ袋中1枚', '袋代 ¥10' ],
      money_pattern: /[¥￥]?\d+/,
      profile: ReceiptAnalysisProfiles.default
    )

    aggregate_failures do
      expect(result.first).to include(
        line_index: 0,
        source_text: 'レジ袋中1枚',
        normalized_text: 'レジ袋中1枚'
      )
      expect(result.first[:tokens]).to contain_exactly(include(kind: :quantity, amount: 1))
      expect(result.second[:tokens]).to contain_exactly(
        include(kind: :money, amount: 10, span_start: 3, span_end: 6)
      )
    end
  end
end
