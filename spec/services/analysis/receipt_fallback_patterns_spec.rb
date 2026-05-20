require 'rails_helper'

RSpec.describe Analysis::ReceiptFallbackPatterns do
  describe '.detect_category' do
    it '安全な食品語を food に分類する' do
      aggregate_failures do
        expect(described_class.detect_category('バナナ 1袋')).to eq('food')
        expect(described_class.detect_category('ヨーグルト(プレーン)')).to eq('food')
        expect(described_class.detect_category('ミニトマト 1パック')).to eq('food')
        expect(described_class.detect_category('チョコチップクッキー')).to eq('food')
      end
    end

    it '安全な飲料語を drink に分類する' do
      aggregate_failures do
        expect(described_class.detect_category('特選牛乳1000ml')).to eq('drink')
        expect(described_class.detect_category('カフェラテ 500ml')).to eq('drink')
        expect(described_class.detect_category('天然水 2L')).to eq('drink')
        expect(described_class.detect_category('オレンジジュース 500ml')).to eq('drink')
      end
    end

    it '安全な日用品語を daily_goods に分類する' do
      aggregate_failures do
        expect(described_class.detect_category('乾電池 単3')).to eq('daily_goods')
        expect(described_class.detect_category('やわらかティッシュ 5P')).to eq('daily_goods')
      end
    end

    it '安全な趣味語を hobby に分類する' do
      aggregate_failures do
        expect(described_class.detect_category('ノート A5')).to eq('hobby')
        expect(described_class.detect_category('ボールペン(黒)')).to eq('hobby')
        expect(described_class.detect_category('クリアファイル A4')).to eq('hobby')
        expect(described_class.detect_category('修正テープ')).to eq('hobby')
        expect(described_class.detect_category('文庫本')).to eq('hobby')
      end
    end

    it '安全な交通語を transportation に分類する' do
      expect(described_class.detect_category('高速道路料金')).to eq('transportation')
    end

    it '危険な短い語だけではカテゴリを決めない' do
      aggregate_failures do
        expect(described_class.detect_category('水道')).to eq('other')
        expect(described_class.detect_category('きゅうり 1本')).to eq('other')
        expect(described_class.detect_category('本日のパスタ')).to eq('food')
        expect(described_class.detect_category('USB3.0 高速転送')).to eq('other')
        expect(described_class.detect_category('おすすめ商品')).to eq('other')
        expect(described_class.detect_category('セール価格')).to eq('other')
      end
    end

    it 'enum外のカテゴリを返さない' do
      detected_categories = [
        'バナナ 1袋',
        '特選牛乳1000ml',
        '乾電池 単3',
        'ノート A5',
        '高速道路料金',
        'おすすめ商品'
      ].map { |text| described_class.detect_category(text) }

      expect(detected_categories).to all(satisfy { |category| ReceiptItem::CATEGORIES.include?(category) })
    end
  end
end
