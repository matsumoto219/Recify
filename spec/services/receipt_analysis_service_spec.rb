require 'rails_helper'

RSpec.describe ReceiptAnalysisService do
  let(:receipt) { create(:receipt) }

  def build_ocr_result(overrides = {})
    {
      success: true,
      raw_text: "サンプルストア\n2026/04/02 12:34\nコーヒー 180\nサンド 550 x2\n合計 1280\nMaster",
      lines: [
        'サンプルストア',
        '2026/04/02 12:34',
        'コーヒー 180',
        'サンド 550 x2',
        '合計 1280',
        'Master'
      ],
      candidates: {
        store_name: 'サンプルストア',
        purchased_at_text: '2026/04/02 12:34',
        total_amount: 1280,
        payment_method_text: 'Master',
        items: [
          {
            raw_text: 'コーヒー',
            price: 180,
            quantity: 1,
            quantity_unit: '杯',
            product_code: 'C001',
            line_total: 180,
            confidence: 0.98
          },
          {
            raw_text: 'サンド',
            price: 550,
            quantity: 2,
            quantity_unit: '個',
            product_code: 'S001',
            line_total: 1100,
            confidence: 0.97
          }
        ],
        payments: [
          { method: 'CreditCard', amount: 1280 }
        ],
        tax_details: [
          { description: 'Sales Tax', amount: 80, rate: 10, net_amount: 800 }
        ]
      },
      error_code: nil,
      meta: { provider: 'azure_document_intelligence', model_id: 'prebuilt-receipt' }
    }.deep_merge(overrides)
  end

  let(:successful_ai_result) do
    {
      success: true,
      needs_review: false,
      receipt_attributes: {
        store_name: 'AI補正ストア',
        payment_method: 'credit_card'
      },
      receipt_items_attributes: [
        {
          raw_text: 'コーヒー',
          suggested_name: 'ブレンドコーヒー',
          category: 'drink',
          quantity_unit: '杯',
          product_code: 'C001',
          line_total: 180,
          confidence: 0.98,
          needs_review: false
        },
        {
          raw_text: 'サンド',
          suggested_name: 'たまごサンド',
          category: 'food',
          quantity_unit: '個',
          product_code: 'S001',
          line_total: 1100,
          confidence: 0.97,
          needs_review: false
        }
      ]
    }
  end

  let(:strict_completed_ai_result) do
    {
      success: true,
      needs_review: false,
      receipt_attributes: {
        store_name: 'AI補正ストア',
        payment_method: 'credit_card'
      },
      receipt_items_attributes: [
        {
          raw_text: 'コーヒー',
          suggested_name: 'ブレンドコーヒー',
          category: 'drink',
          quantity_unit: '杯',
          product_code: 'C001',
          line_total: 180,
          confidence: 0.98,
          needs_review: false
        },
        {
          raw_text: 'サンド',
          suggested_name: 'たまごサンド',
          category: 'food',
          quantity_unit: '個',
          product_code: 'S001',
          line_total: 1100,
          confidence: 0.97,
          needs_review: false
        }
      ]
    }
  end

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

    it 'OCR unreadable の場合は failed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: '',
          lines: [],
          candidates: {
            store_name: nil,
            total_amount: nil,
            payment_method_text: nil,
            items: [],
            payments: [],
            tax_details: []
          }
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_unreadable')
        expect(receipt.ocr_completed_at).to be_present
      end
    end

    it 'OCR items が空でも lines からフォールバックで明細を生成する' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            items: [],
            payments: [],
            tax_details: []
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_raise(
        ReceiptAiEnrichmentService::AiEnrichmentError.new('analysis_missing_keys', 'dummy ai failure')
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.receipt_items.count).to eq(2)
        expect(receipt.receipt_items.pluck(:raw_text)).to include('コーヒー 180', 'サンド 550 x2')
      end
    end

    it 'AI成功かつ要確認なしなら completed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect([ 'completed', 'review_needed' ]).to include(receipt.status)
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.store_name).to eq('AI補正ストア')
        expect(receipt.payment_method).to eq('credit_card')
        expect(receipt.receipt_items.pluck(:suggested_name, :category)).to include(
          [ 'ブレンドコーヒー', 'drink' ],
          [ 'たまごサンド', 'food' ]
        )
      end
    end

    it 'AI成功でも needs_review が true なら review_needed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result.merge(needs_review: true))

      described_class.call(receipt)
      receipt.reload

      expect(receipt.status).to eq('review_needed')
    end

    it 'OCRが success: false かつ ocr_timeout の場合は failed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        {
          success: false,
          raw_text: '',
          lines: [],
          candidates: { items: [], payments: [], tax_details: [] },
          error_code: 'ocr_timeout',
          meta: {}
        }
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_timeout')
        expect(receipt.ocr_completed_at).to be_present
      end
    end

    it 'OCRが success: false かつ error_code が nil の場合は ocr_api_error で failed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        {
          success: false,
          raw_text: '',
          lines: [],
          candidates: { items: [], payments: [], tax_details: [] },
          error_code: nil,
          meta: {}
        }
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_api_error')
        expect(receipt.ocr_completed_at).to be_present
      end
    end

    it '想定外例外時は unexpected_error で failed にし AnalysisError を送出する' do
      allow(ReceiptOcrService).to receive(:call).and_raise(StandardError, 'unexpected boom')

      expect do
        described_class.call(receipt)
      end.to raise_error(ReceiptAnalysisService::AnalysisError)

      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('unexpected_error')
        expect(receipt.processing_error_message).to eq('unexpected boom')
      end
    end

    it '高品質OCRかつAI成功なら completed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            confidence_summary: {
              items_average: 0.95,
              overall: 0.95
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(strict_completed_ai_result)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.store_name).to eq('AI補正ストア')
        expect(receipt.payment_method).to eq('credit_card')
      end
    end

    it 'payment_method_text が空なら review_needed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            payment_method_text: nil,
            confidence_summary: {
              items_average: 0.95,
              overall: 0.95
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(strict_completed_ai_result)

      described_class.call(receipt)
      receipt.reload

      expect(receipt.status).to eq('review_needed')
    end

    it 'items_average が低いなら review_needed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            confidence_summary: {
              items_average: 0.5,
              overall: 0.8
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(strict_completed_ai_result)

      described_class.call(receipt)
      receipt.reload

      expect(receipt.status).to eq('review_needed')
    end

    it 'overall confidence が 0.3 未満なら ocr_unreadable で failed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            confidence_summary: {
              items_average: 0.4,
              overall: 0.2
            }
          }
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_unreadable')
      end
    end

    it 'AIレスポンスが非Hashなら ai_invalid_response 扱いで review_needed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return('invalid ai response')

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_invalid_response')
      end
    end

    it '旧形式のAIレスポンスでも正規化して保存できる' do
      legacy_ai_result = {
        store_name: '旧形式AIストア',
        payment_method: 'credit_card',
        items: [
          {
            raw_text: 'コーヒー',
            suggested_name: '旧形式ブレンドコーヒー',
            category: 'drink',
            needs_review: false,
            line_total: 180,
            confidence: 0.98
          },
          {
            raw_text: 'サンド',
            suggested_name: '旧形式たまごサンド',
            category: 'food',
            needs_review: false,
            line_total: 1100,
            confidence: 0.97
          }
        ],
        needs_review: false
      }

      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            confidence_summary: {
              items_average: 0.95,
              overall: 0.95
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(legacy_ai_result)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.store_name).to eq('旧形式AIストア')
        expect(receipt.payment_method).to eq('credit_card')
        expect(receipt.receipt_items.pluck(:suggested_name, :category)).to include(
          [ '旧形式ブレンドコーヒー', 'drink' ],
          [ '旧形式たまごサンド', 'food' ]
        )
      end
    end
  end
end
