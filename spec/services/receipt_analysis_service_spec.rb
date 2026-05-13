require 'rails_helper'

RSpec.describe ReceiptAnalysisService do
  let(:receipt) { create(:receipt, :with_image) }

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
        tip_amount: 100,
        country_region: 'JP',
        receipt_type: 'Meal',
        payment_method_text: 'Master',
        items: [
          {
            raw_text: 'コーヒー',
            price: 180,
            quantity: 1,
            quantity_unit: '杯',
            product_code: 'C001',
            line_total: 180,
            tax_rate: 10,
            confidence: 0.98
          },
          {
            raw_text: 'サンド',
            price: 550,
            quantity: 2,
            quantity_unit: '個',
            product_code: 'S001',
            line_total: 1100,
            tax_rate: 10,
            confidence: 0.97
          }
        ],
        payments: [
          { method: 'CreditCard', amount: 1280 }
        ],
        tax_details: [
          { description: 'Sales Tax', amount: 116, rate: 10, net_amount: 1164 }
        ]
      },
      error_code: nil,
      meta: {
        provider: 'azure_document_intelligence',
        model_id: 'prebuilt-receipt',
        confidence_summary: {
          items_average: 0.95,
          overall: 0.95
        }
      }
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
          index: 0,
          suggested_name: 'ブレンドコーヒー',
          category: 'drink',
          quantity_unit: '杯',
          product_code: 'C001',
          line_total: 180,
          tax_rate: BigDecimal("0.1"),
          confidence: 0.98,
          needs_review: false
        },
        {
          index: 1,
          suggested_name: 'たまごサンド',
          category: 'food',
          quantity_unit: '個',
          product_code: 'S001',
          line_total: 1100,
          tax_rate: BigDecimal("0.1"),
          confidence: 0.97,
          needs_review: false
        }
      ]
    }
  end

  let(:failed_ai_result) do
    {
      success: false,
      error_code: 'analysis_missing_keys',
      receipt_attributes: {},
      receipt_items_attributes: []
    }
  end

  def amount_result(inconsistencies:, blocking_inconsistencies:, warning_inconsistencies:)
    {
      resolved: {
        total: 1280,
        subtotal: 1164,
        tax: 116,
        tax_rate: BigDecimal('0.1')
      },
      computed: {
        items: []
      },
      tax_details: [],
      inconsistencies: inconsistencies,
      blocking_inconsistencies: blocking_inconsistencies,
      warning_inconsistencies: warning_inconsistencies,
      mismatch_codes: inconsistencies.filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency) },
      blocking_mismatch_codes: blocking_inconsistencies.filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency) },
      warning_mismatch_codes: warning_inconsistencies.filter_map { |inconsistency| Amounts::MismatchCodes.code(inconsistency) },
      warning_reasons: warning_inconsistencies.map(&:to_s),
      mismatch_messages: [],
      needs_review: blocking_inconsistencies.any?
    }
  end

  describe '.call' do
    it 'OCR結果からレシート情報を保存する' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)
      described_class.call(receipt)

      receipt.reload

      expect(receipt.store_name).to eq("サンプルストア")
      expect(receipt.total_amount).to eq(1280)
      expect(receipt.tip_amount).to eq(100)
      expect(receipt.country_region).to eq("JP")
      expect(receipt.receipt_type).to eq("Meal")
    end

    it '明細が保存される' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)
      described_class.call(receipt)

      receipt.reload

      expect(receipt.receipt_items.count).to eq(2)

      item = receipt.receipt_items.first
      expect(item.quantity_unit).to be_present
      expect(item.product_code).to be_present
    end

    it '支払い情報が保存される' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)
      described_class.call(receipt)

      receipt.reload

      expect(receipt.receipt_payments.count).to eq(1)

      payment = receipt.receipt_payments.first
      expect(payment.method).to eq("CreditCard")
      expect(payment.amount).to eq(1280)
    end

    it '税情報が保存される' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)
      described_class.call(receipt)

      receipt.reload

      expect(receipt.receipt_tax_details.count).to eq(1)

      tax = receipt.receipt_tax_details.first
      expect(tax.amount).to eq(116)
      expect(tax.rate).to eq(BigDecimal("0.1"))
    end

    it 'AI失敗時はreview_neededになる' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)

      described_class.call(receipt)
      receipt.reload

      expect(receipt.status).to eq("review_needed")
      expect(receipt.processing_error_code).to eq("analysis_missing_keys")
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
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.receipt_items.count).to eq(2)
        expect(receipt.receipt_items.pluck(:raw_text)).to include('コーヒー 180', 'サンド 550 x2')
      end
    end

    it 'AI成功時に補完結果を保存できる' do
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

    it 'warning mismatch only does not add amount review_reasons or review_needed status' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(candidates: { tip_amount: nil, tax_details: [] })
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [:ocr_total_mismatch],
          blocking_inconsistencies: [],
          warning_inconsistencies: [:ocr_total_mismatch]
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
      end
    end

    it 'blocking mismatch adds amount review_reasons and review_needed status' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(candidates: { tip_amount: nil, tax_details: [] })
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [:tax_detail_mismatch],
          blocking_inconsistencies: [:tax_detail_mismatch],
          warning_inconsistencies: []
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq(['tax_detail_mismatch'])
      end
    end

    it 'mixed mismatch stores only blocking amount review_reasons' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(candidates: { tip_amount: nil, tax_details: [] })
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [:ocr_total_mismatch, :tax_detail_mismatch],
          blocking_inconsistencies: [:tax_detail_mismatch],
          warning_inconsistencies: [:ocr_total_mismatch]
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq(['tax_detail_mismatch'])
      end
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
        expect(receipt.processing_error_message).to be_present
      end
    end

    it '高品質OCRかつAI成功なら completed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            tip_amount: nil,
            tax_details: []
          },
          meta: {
            confidence_summary: {
              items_average: 0.95,
              overall: 0.95
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.store_name).to eq('AI補正ストア')
        expect(receipt.payment_method).to eq('credit_card')
      end
    end

    it 'payment_method_text が空でも payment_method が確定していれば completed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            payment_method_text: nil,
            tip_amount: nil,
            tax_details: []
          },
          meta: {
            confidence_summary: {
              items_average: 0.95,
              overall: 0.95
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)
      receipt.reload

      expect(receipt.status).to eq('completed')
    end

    it 'confidence_summary だけでは review_needed にならず completed のままになる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          candidates: {
            tip_amount: nil,
            tax_details: []
          },
          meta: {
            confidence_summary: {
              items_average: 0.5,
              overall: 0.8
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)
      receipt.reload

      expect(receipt.status).to eq('completed')
    end

    it 'overall confidence が 0.3 未満でも主要項目が揃っていれば review_needed になる' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          meta: {
            confidence_summary: {
              items_average: 0.4,
              overall: 0.2
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('analysis_missing_keys')
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
  end
end
