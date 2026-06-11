require 'rails_helper'

RSpec.describe Analysis::StoreNameCandidateClassifier do
  describe '.customer_facing_heading_candidates' do
    it 'ロゴ由来の孤立1文字を見出し候補へ含めず、後続の自然な店名候補を使う' do
      lines = [
        'プ',
        'Sample Life Market',
        'サンプルライフマーケット 恵比寿店',
        '東京都渋谷区サンプル1-2-3'
      ]

      candidates = described_class.customer_facing_heading_candidates(lines)

      aggregate_failures do
        expect(candidates).to include('Sample Life Market サンプルライフマーケット 恵比寿店')
        expect(candidates).not_to include('プ Sample Life Market')
        expect(candidates).not_to include('プ')
      end
    end

    it '記号始まりの短いロゴ片を見出し候補へ含めず、後続の自然な店名候補を使う' do
      lines = [
        '/smp',
        'サンプル中央店',
        'TEL 000-0000-0000',
        '領収証'
      ]

      candidates = described_class.customer_facing_heading_candidates(lines)

      aggregate_failures do
        expect(candidates).to include('サンプル中央店')
        expect(candidates).not_to include('/smp')
        expect(candidates).not_to include('/smp サンプル中央店')
      end
    end

    it '英字ロゴ行とローカル完結店舗名が隣接する場合はローカル店舗名を優先する' do
      lines = [
        'SampleBrand',
        'サンプルブランド東京中央店',
        'TEL 000-0000-0000',
        '領収証'
      ]

      candidates = described_class.customer_facing_heading_candidates(lines)

      aggregate_failures do
        expect(candidates.first).to eq('サンプルブランド東京中央店')
        expect(candidates).to include('SampleBrand')
        expect(candidates).not_to include('SampleBrand サンプルブランド東京中央店')
      end
    end

    it '上部の施設名と売場名を結合する' do
      lines = [
        'サンプル公園',
        '駐車場',
        '領収書',
        'サンプル公園指定管理者',
        '株式会社',
        'サンプル管理'
      ]

      # 上部見出し2行を顧客向け施設名として結合する:
      # 「サンプル公園」 + 「駐車場」 = 「サンプル公園駐車場」
      expect(described_class.customer_facing_heading_candidates(lines)).to include('サンプル公園駐車場')
    end

    it '海外風の施設名と売場名を空白区切りで結合する' do
      lines = [
        'Harbor Parking',
        'North Garage',
        'Receipt',
        'Managed by',
        'Harima House Ltd.'
      ]

      expect(described_class.customer_facing_heading_candidates(lines)).to include('Harbor Parking North Garage')
    end

    it '業態説明だけの見出しを店舗名候補へ過剰結合しない' do
      lines = [
        'イタリアンワイン&カフェレストラン',
        'サンプルレストラン',
        'サンプルモール渋谷',
        'tel 03-0000-0000',
        '領収証'
      ]

      candidates = described_class.customer_facing_heading_candidates(lines)

      aggregate_failures do
        expect(candidates).to include('サンプルレストランサンプルモール渋谷')
        expect(candidates).not_to include('イタリアンワイン&カフェレストランサンプルレストランサンプルモール渋谷')
      end
    end

    it '販促文や営業時間案内を店舗名候補へ結合しない' do
      lines = [
        'プロの品質とプロの価格',
        'サンプルスーパー 東京中央店',
        '毎日安い!この価格!',
        '営業時間AM9:00〜PM9:00',
        '領収証'
      ]

      candidates = described_class.customer_facing_heading_candidates(lines)

      aggregate_failures do
        expect(candidates).to include('サンプルスーパー 東京中央店')
        expect(candidates).not_to include('プロの品質とプロの価格サンプルスーパー東京中央店')
        expect(candidates).not_to include('サンプルスーパー東京中央店毎日安い!この価格!')
        expect(candidates).not_to include('営業時間AM9:00~PM9:00')
      end
    end
  end

  describe '.store_message_line?' do
    it '店舗名ではなく広告文・営業案内として扱う行を判定する' do
      aggregate_failures do
        expect(described_class.store_message_line?('毎日安い!この価格!')).to be(true)
        expect(described_class.store_message_line?('プロの品質とプロの価格')).to be(true)
        expect(described_class.store_message_line?('営業時間AM9:00〜PM9:00')).to be(true)
        expect(described_class.store_message_line?('Open Daily 9:00-21:00')).to be(true)
        expect(described_class.store_message_line?('サンプルスーパー 東京中央店')).to be(false)
        expect(described_class.store_message_line?('SampleMart Downtown')).to be(false)
      end
    end
  end

  describe '.isolated_logo_fragment?' do
    it '孤立したカタカナ1文字をロゴ片候補として扱い、英字や漢字の1文字ブランドは除外しない' do
      aggregate_failures do
        expect(described_class.isolated_logo_fragment?('プ')).to be(true)
        expect(described_class.isolated_logo_fragment?('/smp')).to be(true)
        expect(described_class.isolated_logo_fragment?('Q')).to be(false)
        expect(described_class.isolated_logo_fragment?('一')).to be(false)
        expect(described_class.isolated_logo_fragment?('Sample Life Market')).to be(false)
      end
    end
  end

  describe '.complete_local_store_name?' do
    it 'ローカル表記だけで完結した店舗名と支店名だけの行を区別する' do
      aggregate_failures do
        expect(described_class.complete_local_store_name?('サンプルブランド東京中央店')).to be(true)
        expect(described_class.complete_local_store_name?('中央南三丁目店')).to be(false)
      end
    end
  end

  describe '.operator_candidates' do
    it '指定管理者近傍の法人名を運営主体候補にする' do
      lines = [
        'サンプル公園指定管理者',
        '株式会社',
        '1責',
        'サンプル管理'
      ]

      expect(described_class.operator_candidates(lines)).to include('株式会社サンプル管理')
    end

    it '各国固有の法人格とoperator文脈を運営主体候補として扱う' do
      lines = [
        'SampleMart Downtown',
        'Operated by',
        'Sample Retail LLC',
        'Managed by',
        'Sample Verwaltung GmbH',
        'Franchisee',
        'Sample Foods Pty Ltd'
      ]

      candidates = described_class.operator_candidates(lines)

      aggregate_failures do
        expect(candidates).to include('Sample Retail LLC')
        expect(candidates).to include('Sample Verwaltung GmbH')
        expect(candidates).to include('Sample Foods Pty Ltd')
        expect(candidates).not_to include('SampleMart Downtown')
      end
    end

    it '完全な法人名の次行にある支店・場所名を運営主体候補へ連結しない' do
      lines = [
        'サンプル食堂',
        '株式会社サンプル食堂',
        'サンプル通り',
        '東京都渋谷区道玄坂1-2-3'
      ]

      candidates = described_class.operator_candidates(lines)

      aggregate_failures do
        expect(candidates).to include('株式会社サンプル食堂')
        expect(candidates).not_to include('株式会社サンプル食堂サンプル通り')
      end
    end
  end

  describe '.brand_candidate_from_legal_entity' do
    it '日本の法人格を除去してブランド候補を生成する' do
      expect(described_class.brand_candidate_from_legal_entity('株式会社サンプル食堂')).to eq('サンプル食堂')
    end

    it '海外の強い法人接尾辞だけを除去してブランド候補を生成する' do
      aggregate_failures do
        expect(described_class.brand_candidate_from_legal_entity('ABC LLC')).to eq('ABC')
        expect(described_class.brand_candidate_from_legal_entity('Sample Coffee Company LLC')).to eq('Sample Coffee Company')
      end
    end

    it '法人格だけの行からはブランド候補を生成しない' do
      expect(described_class.brand_candidate_from_legal_entity('株式会社')).to be_nil
    end
  end

  describe '.operator_legal_entity_candidate?' do
    it 'operator文脈がない唯一の法人店舗名は運営主体扱いにしない' do
      lines = [
        'ABC Stores Inc.',
        'Receipt',
        'Total $10.00'
      ]

      expect(described_class.operator_legal_entity_candidate?('ABC Stores Inc.', lines)).to be(false)
    end

    it 'managed by文脈にある法人名は運営主体扱いにする' do
      lines = [
        'Harbor Parking',
        'Receipt',
        'Managed by',
        'Harima House Ltd.'
      ]

      expect(described_class.operator_legal_entity_candidate?('Harima House Ltd.', lines)).to be(true)
    end
  end
end
