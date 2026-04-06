require 'rails_helper'

RSpec.describe ReceiptAnalysisService do
  let(:receipt) { create(:receipt) }

  before do
    # ダミー画像
    receipt.image.attach(
      io: File.open(Rails.root.join('spec/fixtures/files/test.jpg')),
      filename: 'test.jpg',
      content_type: 'image/jpeg'
    )
  end

  describe '.call' do
    it 'OCR結果からレシート情報を保存する' do
      described_class.call(receipt)

      receipt.reload

      expect(receipt.store_name).to eq("サンプルストア")
      expect(receipt.total_amount).to eq(1280)
      expect(receipt.tip_amount).to eq(100)
      expect(receipt.country_region).to eq("JP")
      expect(receipt.receipt_type).to eq("Meal")
    end

    it '明細が保存される' do
      described_class.call(receipt)

      receipt.reload

      expect(receipt.receipt_items.count).to eq(2)

      item = receipt.receipt_items.first
      expect(item.quantity_unit).to be_present
      expect(item.product_code).to be_present
    end

    it '支払い情報が保存される' do
      described_class.call(receipt)

      receipt.reload

      expect(receipt.receipt_payments.count).to eq(1)

      payment = receipt.receipt_payments.first
      expect(payment.method).to eq("CreditCard")
      expect(payment.amount).to eq(1280)
    end

    it '税情報が保存される' do
      described_class.call(receipt)

      receipt.reload

      expect(receipt.receipt_tax_details.count).to eq(1)

      tax = receipt.receipt_tax_details.first
      expect(tax.amount).to eq(80)
      expect(tax.rate.to_i).to eq(10)
    end

    it 'AI失敗時はreview_neededになる' do
      described_class.call(receipt)

      receipt.reload

      expect(receipt.status).to eq("review_needed")
      expect(receipt.processing_error_code).to eq("analysis_missing_keys")
    end
  end
end
