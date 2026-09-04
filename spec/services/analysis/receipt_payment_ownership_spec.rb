require 'rails_helper'

RSpec.describe Analysis::ReceiptBuildParamsService do
  describe '.call' do
    let(:ocr_result) do
      {
        candidates: {
          total_amount: 1_273,
          payment_method_text: '現金',
          items: [ { raw_text: '検証品', line_total: 1_273 } ],
          payments: [],
          tax_details: []
        },
        lines: []
      }
    end

    def payment_params(lines, ai_method: nil)
      ocr_result[:lines] = lines
      ai_result = ai_method ? { receipt_attributes: { payment_method: ai_method } } : nil
      described_class.call(ocr_result: ocr_result, ai_result: ai_result)
    end

    it '明示された支払方法と金額を総額行に継承したfallbackより優先する' do
      params = payment_params(
        [ '合計金額', '1273', 'モバイル決済領収額', '1273', '現金領収額', '0', '支払方法', 'auPAY', '1273' ],
        ai_method: 'e_money'
      )

      aggregate_failures do
        expect(params[:receipt_payments_attributes]).to contain_exactly(include(method: 'auPAY', amount: 1_273))
        expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
        expect(params[:review_reasons]).not_to include('payment_method_uncertain')
      end
    end

    it '総額行と実決済blockの順序を反転しても支払方法が変わらない' do
      summary = [ '合計金額', '1273', '現金領収額', '0' ]
      payment = [ '支払方法', 'auPAY', '1273' ]

      [ summary + payment, payment + summary ].each do |lines|
        params = payment_params(lines, ai_method: 'e_money')

        expect(params[:receipt_payments_attributes]).to contain_exactly(include(method: 'auPAY', amount: 1_273))
        expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
      end
    end

    it '明示0円の支払方法へ総額を借用しない' do
      params = payment_params([ '合計金額', '1273', '現金領収額', '0' ])

      aggregate_failures do
        expect(params[:receipt_payments_attributes]).to eq([])
        expect(params[:receipt_attributes][:payment_method]).to be_nil
      end
    end

    it '同じ行の0円も欠損ではなくfallbackを否定する根拠として扱う' do
      params = payment_params([ '合計金額 1273円', '現金領収額 0円' ])

      expect(params[:receipt_payments_attributes]).to eq([])
      expect(params[:receipt_attributes][:payment_method]).to be_nil
    end

    it '0円の補助行があっても独立した正の実決済を消さない' do
      params = payment_params([ '合計金額', '1273', '現金領収額', '0', '現金支払 1273円' ])

      expect(params[:receipt_payments_attributes]).to contain_exactly(include(method: '現金支払', amount: 1_273))
      expect(params[:receipt_attributes][:payment_method]).to eq('cash')
    end

    it '支払方法に帰属しない商品や税の0円ではfallbackを否定しない' do
      ocr_result[:candidates][:payment_method_text] = 'Mastercard'
      params = payment_params([ 'クレジットカード売上票', '金額', '1273', '税額 0円' ])

      expect(params[:receipt_payments_attributes]).to contain_exactly(include(method: 'Mastercard', amount: 1_273))
      expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
    end

    it '同じ強さの異なる全額決済が競合した場合は行順で選ばず確認を残す' do
      [ [ '現金支払 1273円', 'auPAY支払 1273円' ], [ 'auPAY支払 1273円', '現金支払 1273円' ] ].each do |payments|
        params = payment_params([ '合計金額 1273円', *payments ])

        aggregate_failures do
          expect(params[:receipt_payments_attributes]).to eq([])
          expect(params[:receipt_attributes][:payment_method]).to be_nil
          expect(params[:review_reasons]).to include('payment_method_uncertain')
        end
      end
    end

    it '実決済の分割支払を残し総額から作ったfallbackを加算しない' do
      params = payment_params([ '合計金額', '1273', '現金支払 273円', 'auPAY支払 1000円' ])

      expect(params[:receipt_payments_attributes]).to contain_exactly(
        include(method: '現金支払', amount: 273),
        include(method: 'auPAY支払', amount: 1_000)
      )
    end

    it '不完全な実決済を総額とfallbackの組で埋め合わせない' do
      params = payment_params([ '合計金額', '1273', 'auPAY支払 1000円' ])

      expect(params[:receipt_payments_attributes]).to contain_exactly(include(method: 'auPAY支払', amount: 1_000))
      expect(params[:receipt_payments_attributes]).not_to include(include(method: '現金'))
    end

    it '未知の決済ブランドを既知の方法へ推測変換しない' do
      ocr_result[:candidates][:payment_method_text] = 'StarPay'
      params = payment_params([ '合計金額', '1273', '支払方法', 'StarPay', '1273' ])

      expect(params[:receipt_attributes][:payment_method]).to be_nil
      expect(params[:receipt_payments_attributes]).to eq([])
    end

    it '競合のないカード売上票では金額ラベルの既存fallbackを維持する' do
      ocr_result[:candidates][:payment_method_text] = 'Mastercard'
      params = payment_params([ 'クレジットカード売上票', 'カード会社', 'Mastercard(307)', '金額', '1273', '合計金額', '1273' ])

      expect(params[:receipt_payments_attributes]).to contain_exactly(include(method: 'Mastercard', amount: 1_273))
      expect(params[:receipt_attributes][:payment_method]).to eq('credit_card')
    end

    it '同一方法の別表記で全額が重複する場合は同じ支払として一度だけ採用する' do
      params = payment_params([ '支払方法', 'auPAY', '1273', 'auPAY支払 1273円' ])

      expect(params[:receipt_payments_attributes].size).to eq(1)
      expect(params[:receipt_payments_attributes].sum { |payment| payment[:amount] }).to eq(1_273)
      expect(params[:receipt_attributes][:payment_method]).to eq('qr_payment')
    end

    it '候補選択用の内部属性を保存値へ出さず入力も変更しない' do
      ocr_result[:lines] = [ '合計金額', '1273', '支払方法', 'auPAY', '1273' ]
      before = ocr_result.deep_dup

      params = described_class.call(ocr_result: ocr_result, ai_result: nil)

      expect(ocr_result).to eq(before)
      expect(params[:receipt_payments_attributes].first.keys).to contain_exactly(:method, :amount)
    end
  end
end
