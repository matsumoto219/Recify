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

    it '2文字のJP aliasはJapan profileへ対応させない' do
      expect(described_class.fetch('JP')).to be_nil
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

  describe 'JPN profile generated labels' do
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

  describe 'JPN profile OCR date patterns' do
    it 'OCR購入日のfallback表記をprofile側で定義する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect(profile.ocr_purchased_at_date_patterns.any? { |pattern| '2026年05月20日'.match?(pattern) }).to be(true)
        expect(profile.ocr_purchased_at_date_patterns.any? { |pattern| '2026-05-20'.match?(pattern) }).to be(true)
      end
    end
  end

  describe 'JPN profile OCR payment adjustment discount labels' do
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

  describe 'JPN profile OCR payment method exclusion labels' do
    it '支払方法へ昇格させない調整・精算行をprofile側で定義する' do
      pattern = described_class.fetch('JPN').ocr_payment_method_excluded_line_pattern

      aggregate_failures do
        expect('お預かり cash 1,000').to match(pattern)
        expect('お釣り cash 100').to match(pattern)
        expect('change cash 100').to match(pattern)
        expect('ポイント利用 -100').to match(pattern)
        expect('ポイント付与 10P').to match(pattern)
        expect('クーポン値引き -100').to match(pattern)
        expect('coupon -100').to match(pattern)
        expect('支払時割引 -40').to match(pattern)
        expect('キャッシュレス還元額 -50').to match(pattern)
        expect('cashless reward -50').to match(pattern)

        expect('クレジット支払 ¥1,900').not_to match(pattern)
        expect('現金').not_to match(pattern)
        expect('電子マネー決済').not_to match(pattern)
        expect('QR決済').not_to match(pattern)
        expect('商品券支払 ¥1,000').not_to match(pattern)
        expect('gift card ¥1,000').not_to match(pattern)
      end
    end
  end

  describe 'JPN profile OCR point usage adjustment labels' do
    it 'OCRポイント利用ラベルと表示用ポイント行をprofile側で定義する' do
      profile = described_class.fetch('JPN')
      usage_pattern = profile.ocr_point_usage_adjustment_label_pattern
      display_pattern = profile.ocr_point_display_line_pattern

      aggregate_failures do
        expect('ポイント利用 -100').to match(usage_pattern)
        expect('ポイント支払 ▲100').to match(usage_pattern)
        expect('point usage -100').to match(usage_pattern)
        expect('ポイント付与 10P').not_to match(usage_pattern)
        expect('獲得予定ポイント 20P').not_to match(usage_pattern)
        expect('保有ポイント 300P').not_to match(usage_pattern)
        expect('利用可能ポイント 200P').not_to match(usage_pattern)
        expect('ポイント付与 10P').to match(display_pattern)
        expect('獲得予定ポイント 20P').to match(display_pattern)
        expect('保有ポイント 300P').to match(display_pattern)
        expect('利用可能ポイント 200P').to match(display_pattern)
      end
    end
  end

  describe 'JPN profile analysis cash tendered payment labels' do
    it 'Amount Engine用の現金預かりラベルをprofile側で定義する' do
      pattern = described_class.fetch('JPN').analysis_cash_tendered_payment_pattern

      aggregate_failures do
        expect('現金').to match(pattern)
        expect('お預かり').to match(pattern)
        expect('預り').to match(pattern)
        expect('クレジット支払').not_to match(pattern)
        expect('電子マネー決済').not_to match(pattern)
        expect('QR決済').not_to match(pattern)
      end
    end
  end

  describe 'JPN profile analysis surcharge labels' do
    it '購入調整の追加料金ラベルをprofile側で定義する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect('配送料').to match(profile.analysis_surcharge_kind_pattern('delivery_fee'))
        expect('レジ袋代').to match(profile.analysis_surcharge_kind_pattern('bag_fee'))
        expect('サービス料10%').to match(profile.analysis_surcharge_kind_pattern('service_charge'))
        expect('深夜料金').to match(profile.analysis_surcharge_kind_pattern('late_night_charge'))
        expect('手数料').to match(profile.analysis_surcharge_kind_pattern('handling_fee'))
        expect(profile.analysis_surcharge_kind_pattern('receipt_discount')).to be_nil
      end
    end
  end

  describe 'JPN profile analysis voucher labels' do
    it '商品券・ストアクレジット系ラベルをprofile側で定義する' do
      pattern = described_class.fetch('JPN').analysis_voucher_payment_pattern

      aggregate_failures do
        expect('商品券').to match(pattern)
        expect('ギフトカード').to match(pattern)
        expect('gift card').to match(pattern)
        expect('store credit').to match(pattern)
        expect('ポイント利用').not_to match(pattern)
      end
    end
  end

  describe 'JPN profile AI support patterns' do
    it 'AI prompt用の日本語ノイズ・日時・支店候補パターンをprofile側で定義する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect('¥1,234').to match(profile.ai_numeric_symbol_only_line_pattern)
        expect('**** **** **** 1234').to match(profile.ai_masked_card_line_pattern)
        expect('10%').to match(profile.ai_percent_line_pattern)
        expect('ご来店ありがとうございました').to match(profile.ai_store_greeting_noise_pattern)
        expect('tax id T1234567890123').to match(profile.ai_store_system_noise_pattern)
        expect('2026年7月5日').to match(profile.ai_local_date_line_pattern)
        expect('123456').to match(profile.ai_branch_numeric_code_pattern)
        expect('2026年').to match(profile.ai_branch_date_fragment_pattern)
        expect('12A').to match(profile.ai_branch_short_code_pattern)
        expect('¥500').to match(profile.ai_branch_currency_pattern)
        expect('東京都').to match(profile.ai_branch_admin_area_pattern)
        expect('123').to match(profile.ai_branch_digit_sequence_pattern)
        expect('2026-07-05').to match(profile.ai_date_time_line_patterns.first)
      end
    end
  end

  describe 'JPN profile purchased_at fallback patterns' do
    it '購入日時fallback用の日付・時刻パターンをprofile側で定義する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect(profile.analysis_purchased_at_date_only_patterns.any? { |pattern| '2026年7月5日'.match?(pattern) }).to be(true)
        expect('有効期限 23:59').to match(profile.analysis_purchase_time_exclusion_pattern)
        expect('時刻 9時05分').to match(profile.analysis_purchase_time_expression_pattern)
      end
    end
  end

  describe 'JPN profile signal patterns' do
    it 'レシート判定用の金額・日時パターンをprofile側で定義する' do
      profile = described_class.fetch('JPN')

      aggregate_failures do
        expect('¥120').to match(profile.signal_money_prefix_pattern)
        expect('120円').to match(profile.signal_money_suffix_pattern)
        expect('2026年7月5日').to match(profile.signal_date_pattern)
        expect(' 120 ').to match(profile.signal_generic_amount_pattern)
        expect(profile.signal_date_time_patterns.any? { |pattern| '2026年7月5日 09:05'.match?(pattern) }).to be(true)
      end
    end
  end

  describe 'JPN profile quantity unit aliases' do
    it 'ReceiptQuantityUnitの保存codeへ正規化できるaliasだけを持つ' do
      aliases = described_class.fetch('JPN').quantity_unit_aliases

      aggregate_failures do
        expect(aliases['個']).to eq('each')
        expect(aliases['kg']).to eq('kilogram')
        expect(aliases['ml']).to eq('milliliter')
        expect(aliases.values.uniq).to all(be_in(ReceiptQuantityUnit.allowed_codes))
      end
    end

    it 'JPN profile経由で数量単位を保存codeへ正規化する' do
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
