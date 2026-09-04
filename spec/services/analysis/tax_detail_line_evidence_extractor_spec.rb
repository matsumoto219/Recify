require 'rails_helper'

RSpec.describe Analysis::TaxDetailLineEvidenceExtractor do
  describe '.call' do
    it '1%の税込対象額から1円の内税を復元する' do
      result = described_class.call(lines: [ '税込1%対象 101円' ], receipt_total: 101, receipt_tax: 1)

      expect(result).to eq([
        { description: '1%対象', rate: BigDecimal('0.01'), net_amount: 100, amount: 1 }
      ])
    end

    it '0.5%の税込対象額から1円の内税を復元する' do
      result = described_class.call(lines: [ '税込0.5%対象 201円' ], receipt_total: 201, receipt_tax: 1)

      expect(result).to eq([
        { description: '0.5%対象', rate: BigDecimal('0.005'), net_amount: 200, amount: 1 }
      ])
    end

    it '全角の小数百分率も同じ税率として復元する' do
      result = described_class.call(lines: [ '税込０．５％対象 ２０１円' ], receipt_total: 201, receipt_tax: 1)

      expect(result).to eq([
        { description: '0.5%対象', rate: BigDecimal('0.005'), net_amount: 200, amount: 1 }
      ])
    end

    it '明示0%と100%の境界を維持する' do
      zero_rate = described_class.call(lines: [ '税込0%対象 100円' ], receipt_total: 100, receipt_tax: 0)
      full_rate = described_class.call(lines: [ '税込100%対象 200円' ], receipt_total: 200, receipt_tax: 100)

      aggregate_failures do
        expect(zero_rate).to eq([
          { description: '0%対象', rate: BigDecimal('0'), net_amount: 100, amount: 0 }
        ])
        expect(full_rate).to eq([
          { description: '100%対象', rate: BigDecimal('1'), net_amount: 100, amount: 100 }
        ])
      end
    end

    it '商品内の税込表記を税率別対象額にせず真正なsummaryを保持する' do
      result = described_class.call(
        lines: [ '例示商品(税込27%)', '単価127円', '数量10個', '明細計1270円', '27%対象計1270円', '内税額270円' ],
        receipt_total: 1270,
        receipt_tax: 270
      )

      expect(result).to eq([
        { description: '27%対象', rate: BigDecimal('0.27'), net_amount: 1000, amount: 270 }
      ])
    end

    it '対象額が欠けたsummaryから後続商品や支払の金額を借用しない' do
      [ '例示商品 単価1270円', '単価1270円', '税込27% 1270円/100g', '数量1270個', '現金1270円', '例示商品' ].each do |line|
        result = described_class.call(lines: [ '27%対象計', line, '1270円' ], receipt_total: 1270, receipt_tax: 270)

        expect(result).to eq([])
      end
    end

    it '分離されたtax-onlyラベルと金額行の既存順序を維持する' do
      result = described_class.call(
        lines: [ '(27%対象', '(内消費税等', '¥1270)', '¥270)' ],
        receipt_total: 1270,
        receipt_tax: 270
      )

      expect(result).to eq([
        { description: '27%対象', rate: BigDecimal('0.27'), net_amount: 1000, amount: 270 }
      ])
    end

    it 'summaryと継続行の語彙は注入profileだけを使う' do
      profile = ReceiptAnalysisProfiles.default.dup
      allow(profile).to receive(:analysis_tax_summary_line_pattern).and_return(/\A27%課税総額\z/)
      allow(profile).to receive(:analysis_tax_target_marker_pattern).and_return(/課税総額/)
      allow(profile).to receive(:analysis_tax_summary_continuation_line_pattern).and_return(/\A集計値1270円\z/)

      accepted = described_class.call(lines: [ '27%課税総額', '集計値1270円' ], receipt_total: 1270, receipt_tax: 270, profile: profile)
      rejected = described_class.call(lines: [ '27%課税総額', '1270円' ], receipt_total: 1270, receipt_tax: 270, profile: profile)
      old_label = described_class.call(lines: [ '27%対象計1270円' ], receipt_total: 1270, receipt_tax: 270, profile: profile)

      aggregate_failures do
        expect(accepted).to eq([
          { description: '27%対象', rate: BigDecimal('0.27'), net_amount: 1000, amount: 270 }
        ])
        expect(rejected).to eq([])
        expect(old_label).to eq([])
      end
    end

    it '既存のpositive decimal rateがある単一税率を再構成しない' do
      [ BigDecimal('0.01'), BigDecimal('0.27'), BigDecimal('1') ].each do |rate|
        existing_tax_details = [ { rate: rate, net_amount: 100, amount: 1 } ]
        original_details = existing_tax_details.deep_dup

        result = described_class.call(
          lines: [ '税込1%対象 101円' ],
          receipt_total: 101,
          receipt_tax: 1,
          existing_tax_details: existing_tax_details
        )

        aggregate_failures(rate) do
          expect(result).to eq([])
          expect(existing_tax_details).to eq(original_details)
        end
      end
    end
  end
end
