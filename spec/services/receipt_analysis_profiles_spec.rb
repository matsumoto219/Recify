require 'rails_helper'

RSpec.describe ReceiptAnalysisProfiles do
  describe '.fetch' do
    it 'JPNの解析profileを返す' do
      expect(described_class.fetch('JPN')).to eq(ReceiptAnalysisProfiles::Japan)
    end

    it 'blank/nilはJapan profileへfallbackする' do
      aggregate_failures do
        expect(described_class.fetch(nil)).to eq(ReceiptAnalysisProfiles::Japan)
        expect(described_class.fetch('')).to eq(ReceiptAnalysisProfiles::Japan)
        expect(described_class.fetch('   ')).to eq(ReceiptAnalysisProfiles::Japan)
      end
    end

    it 'JP aliasもJapan profileへ対応させる' do
      expect(described_class.fetch('JP')).to eq(ReceiptAnalysisProfiles::Japan)
    end

    it '明示的なunsupported countryをJP扱いにしない' do
      expect(described_class.fetch('USA')).to be_nil
    end

    it 'registryにprofileを追加すれば国コードで切り替えられる' do
      test_profile = Module.new

      stub_const(
        'ReceiptAnalysisProfiles::Registry::SUPPORTED_COUNTRY_CODES',
        { 'TST' => test_profile }.freeze
      )

      aggregate_failures do
        expect(described_class.fetch('TST')).to eq(test_profile)
        expect(described_class.fetch('JPN')).to be_nil
      end
    end
  end

  describe 'JP profile generated labels' do
    it '既存の生成ラベルと一致する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect(profile.cash_label).to eq('現金')
        expect(profile.voucher_label).to eq('商品券')
        expect(profile.point_usage_label).to eq('ポイント利用')
        expect(profile.tax_rate_target_label(8)).to eq('8%対象')
        expect(profile.tax_rate_target_label(10)).to eq('10%対象')
      end
    end
  end

  describe 'JP profile OCR date patterns' do
    it 'OCR購入日のfallback表記をprofile側で定義する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect(profile.ocr_purchased_at_date_patterns.any? { |pattern| '2026年05月20日'.match?(pattern) }).to be(true)
        expect(profile.ocr_purchased_at_date_patterns.any? { |pattern| '2026-05-20'.match?(pattern) }).to be(true)
      end
    end
  end

  describe 'JP profile OCR payment adjustment discount labels' do
    it 'OCR支払時割引ラベルをprofile側で定義する' do
      pattern = described_class.fetch('JPN').ocr_payment_adjustment_discount_label_pattern

      aggregate_failures do
        expect('payment discount -40').to match(pattern)
        expect('cashless reward -40').to match(pattern)
        expect('支払時割引 -40').to match(pattern)
        expect('決済割引 -40').to match(pattern)
        expect('キャッシュレス決済還元 -40').to match(pattern)
        expect('クレジット支払 -1,900').not_to match(pattern)
        expect('お預かり -2,000').not_to match(pattern)
      end
    end
  end

  describe 'JP profile quantity unit aliases' do
    it 'ReceiptQuantityUnitの保存codeへ正規化できるaliasだけを持つ' do
      aliases = described_class.fetch('JPN').quantity_unit_aliases

      aggregate_failures do
        expect(aliases['個']).to eq('each')
        expect(aliases['kg']).to eq('kilogram')
        expect(aliases['ml']).to eq('milliliter')
        expect(aliases.values.uniq).to all(be_in(ReceiptQuantityUnit.allowed_codes))
      end
    end

    it 'JP profile経由で数量単位を保存codeへ正規化する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect(profile.normalize_quantity_unit('個')).to eq('each')
        expect(profile.normalize_quantity_unit('kg')).to eq('kilogram')
        expect(profile.normalize_quantity_unit('ml')).to eq('milliliter')
        expect(profile.normalize_quantity_unit('通')).to eq('each')
      end
    end
  end
end
