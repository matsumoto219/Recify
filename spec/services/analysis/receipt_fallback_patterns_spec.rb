require 'rails_helper'

RSpec.describe Analysis::ReceiptFallbackPatterns do
  describe '.detect_payment_method' do
    it '主要な支払方法の表記揺れをカテゴリへ正規化する' do
      cases = {
        'QUICPay' => 'e_money',
        'QUIC Pay' => 'e_money',
        'QuickPay' => 'e_money',
        'QUI CPay' => 'e_money',
        'qui cpay' => 'e_money',
        'iD' => 'e_money',
        'ID' => 'e_money',
        'ｉＤ' => 'e_money',
        'iD支払' => 'e_money',
        'ID支払' => 'e_money',
        'ｉＤ支払' => 'e_money',
        'iD決済' => 'e_money',
        'Suica' => 'e_money',
        'PASMO' => 'e_money',
        'ICOCA' => 'e_money',
        '交通系IC' => 'e_money',
        '交通系電子マネー' => 'e_money',
        'WAON' => 'e_money',
        'nanaco' => 'e_money',
        'Edy' => 'e_money',
        '楽天Edy' => 'e_money',
        '電子マネー支払' => 'e_money',
        'contactless payment' => 'e_money',
        'タッチ決済' => 'e_money',
        'コンタクトレス決済' => 'e_money',
        'NFC payment' => 'e_money',
        'mobile payment' => 'e_money',
        'Apple Pay' => 'e_money',
        'Google Pay' => 'e_money',
        'QR決済' => 'qr_payment',
        'QRコード支払' => 'qr_payment',
        'PayPay' => 'qr_payment',
        '楽天ペイ' => 'qr_payment',
        'Rakuten Pay' => 'qr_payment',
        'd払い' => 'qr_payment',
        'd payment' => 'qr_payment',
        'au PAY' => 'qr_payment',
        'aupay' => 'qr_payment',
        'メルペイ' => 'qr_payment',
        'LINE Pay' => 'qr_payment',
        'Alipay' => 'qr_payment',
        'WeChat Pay' => 'qr_payment',
        'クレジット' => 'credit_card',
        'credit' => 'credit_card',
        'VISA' => 'credit_card',
        'Mastercard' => 'credit_card',
        'Master Card' => 'credit_card',
        'JCB' => 'credit_card',
        'AMEX' => 'credit_card',
        'American Express' => 'credit_card',
        'Diners' => 'credit_card',
        'Discover' => 'credit_card',
        'UnionPay' => 'credit_card',
        'Union Pay' => 'credit_card',
        '銀聯' => 'credit_card',
        '現金' => 'cash',
        'cash' => 'cash',
        'お預り' => 'cash',
        'お釣り' => 'cash',
        '釣銭' => 'cash',
        '現計' => 'cash',
        '現 計' => 'cash',
        'debit' => 'debit_card',
        'デビット' => 'debit_card',
        'Debit Card' => 'debit_card'
      }

      aggregate_failures do
        cases.each do |text, expected|
          expect(described_class.detect_payment_method(text)).to eq(expected), text
        end
      end
    end

    it '広告・対応表記やポイント文脈だけでは代表支払方法にしない' do
      aggregate_failures do
        expect(described_class.detect_payment_method('電子マネー対応')).to be_nil
        expect(described_class.detect_payment_method('PayPay使えます')).to be_nil
        expect(described_class.detect_payment_method('各種クレジット取扱')).to be_nil
        expect(described_class.detect_payment_method('WAON POINT')).to be_nil
        expect(described_class.detect_payment_method('ポイント利用')).to be_nil
        expect(described_class.detect_payment_method('card')).to eq('other')
      end
    end

    it '単語内部のidをiD支払として扱わない' do
      concrete_payment_categories = %w[e_money credit_card qr_payment cash debit_card]

      aggregate_failures do
        expect(described_class.detect_payment_method('sivendidolo ros')).not_to be_in(concrete_payment_categories)
        expect(described_class.detect_payment_method('middle')).not_to be_in(concrete_payment_categories)
        expect(described_class.detect_payment_method('guideline')).not_to be_in(concrete_payment_categories)
      end
    end
  end

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
