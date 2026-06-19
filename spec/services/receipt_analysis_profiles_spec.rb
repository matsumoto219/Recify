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
