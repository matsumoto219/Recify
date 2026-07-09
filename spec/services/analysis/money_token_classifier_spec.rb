require 'rails_helper'

RSpec.describe Analysis::MoneyTokenClassifier do
  let(:money_pattern) { /[▲△\-−]?\s*[¥￥$€£]?\s*(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d+)?(?:円)?/ }
  let(:profile) { ReceiptAnalysisProfiles.default }

  it '数量・率・point・IDらしい数値をmoneyから分離する' do
    cases = {
      'レジ袋中1枚' => :quantity,
      '商品2個' => :quantity,
      '税率10%' => :percent,
      '保有ポイント 500pt' => :point,
      '電話 03-1234-5678' => :id_like,
      'カード番号 1234' => :id_like
    }

    aggregate_failures do
      cases.each do |source, expected_kind|
        result = described_class.call(text: source, money_pattern: money_pattern, profile: profile)

        expect(result).not_to be_empty
        expect(result).to all(include(kind: expected_kind))
      end
    end
  end

  it '通貨・円・符号つき金額をmoneyとして保持する' do
    aggregate_failures do
      [ '袋代 ¥10', '袋代 10円', 'クーポン -100', '値引 ▲100' ].each do |source|
        result = described_class.call(text: source, money_pattern: money_pattern, profile: profile)

        expect(result).to contain_exactly(include(kind: :money, money_evidence: true))
      end
    end
  end

  it '国別patternが通貨記号を含めない場合も直前の通貨記号をmoney根拠として扱う' do
    result = described_class.call(
      text: 'Manual adjustment -$2.00',
      money_pattern: /\d+/,
      profile: profile
    )

    expect(result).to include(include(kind: :money, amount: 2, money_evidence: true))
  end

  it '裸数値は明示許可時だけmoney matchとして返す' do
    denied = described_class.money_matches(
      text: '配送料 550',
      money_pattern: /\d+/,
      profile: profile,
      allow_bare_money: false
    )
    allowed = described_class.money_matches(
      text: '配送料 550',
      money_pattern: /\d+/,
      profile: profile,
      allow_bare_money: true
    )

    aggregate_failures do
      expect(denied).to eq([])
      expect(allowed).to contain_exactly(include(kind: :bare_number, amount: 550))
    end
  end

  it 'token spanを保持する' do
    result = described_class.call(
      text: '袋代 ¥10',
      money_pattern: /[¥￥]?\d+/,
      profile: profile
    ).first

    expect(result).to include(raw_text: '¥10', span_start: 3, span_end: 6)
  end
end
