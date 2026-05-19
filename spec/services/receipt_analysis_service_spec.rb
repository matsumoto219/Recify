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

  def ocr_fixture(name)
    JSON.parse(
      Rails.root.join("spec/fixtures/ocr/#{name}.json").read,
      symbolize_names: true
    )
  end

  def ai_success_result(review_reasons: [], needs_review: false)
    {
      success: true,
      needs_review: needs_review,
      review_reasons: review_reasons,
      receipt_attributes: {
        payment_method: 'cash'
      },
      receipt_items_attributes: []
    }
  end

  def ai_success_result_for(ocr_result, review_reasons: [], needs_review: false)
    ai_success_result(review_reasons: review_reasons, needs_review: needs_review).merge(
      receipt_items_attributes: Array(ocr_result.dig(:candidates, :items)).each_with_index.map do |_item, index|
        {
          index: index,
          category: 'other',
          needs_review: false
        }
      end
    )
  end

  def run_ocr_fixture(name, ai_result: nil)
    captured_amount_result = nil
    ocr_result = ocr_fixture(name)
    ai_result ||= ai_success_result_for(ocr_result)

    allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)
    allow(ReceiptAiEnrichmentService).to receive(:call).and_return(ai_result)
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      captured_amount_result = original.call(**kwargs)
    end

    described_class.call(receipt)
    receipt.reload

    captured_amount_result
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

    it 'AI成功時に割引明細の単価と割引後line_totalを保存する' do
      ocr_result = build_ocr_result(
        candidates: {
          total_amount: 300,
          subtotal_amount: nil,
          tax_amount: nil,
          tip_amount: nil,
          items: [
            {
              raw_text: '割引サンド',
              price: nil,
              quantity: 2,
              quantity_unit: '個',
              original_line_total: 600,
              discount_amount: 300,
              line_total: 300,
              tax_rate: 10,
              confidence: 0.98
            }
          ],
          payments: [],
          tax_details: []
        }
      )

      allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(ai_success_result_for(ocr_result))

      described_class.call(receipt)
      receipt.reload

      item = receipt.receipt_items.first

      aggregate_failures do
        expect(item.price).to eq(300)
        expect(item.quantity).to eq(BigDecimal('2'))
        expect(item.original_line_total).to eq(600)
        expect(item.discount_amount).to eq(300)
        expect(item.line_total).to eq(300)
        expect(receipt.total_amount).to eq(300)
      end
    end

    it 'OCR印字済み割引額を優先してAEON型レシートの金額を壊さない' do
      ocr_result = build_ocr_result(
        candidates: {
          total_amount: 4_215,
          subtotal_amount: 3_903,
          tax_amount: 312,
          tip_amount: nil,
          items: [
            {
              raw_text: '半額商品A',
              price: 271,
              quantity: 1,
              quantity_unit: '個',
              original_line_total: 271,
              discount_amount: 136,
              discount_rate: 50,
              line_total: 135,
              tax_rate: 8,
              confidence: 0.98
            },
            {
              raw_text: '半額商品B',
              price: 489,
              quantity: 1,
              quantity_unit: '個',
              original_line_total: 489,
              discount_amount: 245,
              discount_rate: 50,
              line_total: 244,
              tax_rate: 8,
              confidence: 0.98
            },
            {
              raw_text: '三割引商品',
              price: 432,
              quantity: 1,
              quantity_unit: '個',
              original_line_total: 432,
              discount_amount: 130,
              discount_rate: 30,
              line_total: 302,
              tax_rate: 8,
              confidence: 0.98
            },
            {
              raw_text: '通常商品',
              price: 3_222,
              quantity: 1,
              quantity_unit: '個',
              original_line_total: 3_222,
              discount_amount: 0,
              line_total: 3_222,
              tax_rate: 8,
              confidence: 0.98
            }
          ],
          payments: [],
          tax_details: [
            {
              description: '8%対象',
              rate: 8,
              net_amount: 3_903,
              amount: 312
            }
          ]
        }
      )

      allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(ai_success_result_for(ocr_result))

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.receipt_items.sum(:line_total)).to eq(3_903)
        expect(receipt.subtotal_amount).to eq(3_903)
        expect(receipt.tax_amount).to eq(312)
        expect(receipt.total_amount).to eq(4_215)
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
      end
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

    it 'AI失敗fallbackでもOCR由来の明細・税内訳・支払い情報を保存する' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)

      described_class.call(receipt)
      receipt.reload

      items = receipt.receipt_items.order(:position_index)
      tax_detail = receipt.receipt_tax_details.first
      payment = receipt.receipt_payments.first

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('analysis_missing_keys')
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.store_name).to eq('サンプルストア')
        expect(receipt.total_amount).to eq(1280)
        expect(receipt.subtotal_amount).to eq(1164)
        expect(receipt.tax_amount).to eq(116)
        expect(receipt.review_reasons).to be_blank

        expect(items.size).to eq(2)
        expect(items.first.raw_text).to eq('コーヒー')
        expect(items.first.line_total).to eq(180)
        expect(items.first.quantity_unit).to eq('杯')
        expect(items.second.raw_text).to eq('サンド')
        expect(items.second.quantity).to eq(BigDecimal('2'))
        expect(items.second.line_total).to eq(1100)

        expect(receipt.receipt_tax_details.size).to eq(1)
        expect(tax_detail.description).to eq('10%対象')
        expect(tax_detail.net_amount).to eq(1164)
        expect(tax_detail.amount).to eq(116)
        expect(tax_detail.rate).to eq(BigDecimal('0.1'))

        expect(receipt.receipt_payments.size).to eq(1)
        expect(payment.method).to eq('CreditCard')
        expect(payment.amount).to eq(1280)
      end
    end

    it 'AI down時はAI呼び出しを行わずOCR-only fallbackでreview_neededにする' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ExternalServiceStatus).to receive(:down?).with(:ai).and_return(true)
      expect(ReceiptAiEnrichmentService).not_to receive(:call)

      described_class.call(receipt)
      receipt.reload

      items = receipt.receipt_items.order(:position_index)
      tax_detail = receipt.receipt_tax_details.first
      payment = receipt.receipt_payments.first

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_unavailable')
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.store_name).to eq('サンプルストア')
        expect(receipt.total_amount).to eq(1280)

        expect(items.size).to eq(2)
        expect(items.first.raw_text).to eq('コーヒー')
        expect(items.second.raw_text).to eq('サンド')

        expect(receipt.receipt_tax_details.size).to eq(1)
        expect(tax_detail.net_amount).to eq(1164)
        expect(tax_detail.amount).to eq(116)
        expect(tax_detail.rate).to eq(BigDecimal('0.1'))

        expect(receipt.receipt_payments.size).to eq(1)
        expect(payment.method).to eq('CreditCard')
        expect(payment.amount).to eq(1280)
      end
    end

    it 'AI degraded時は従来どおりAI呼び出しを試す' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ExternalServiceStatus).to receive(:down?).with(:ai).and_return(false)
      allow(ExternalServiceStatus).to receive(:degraded?).with(:ai).and_return(true)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)

      expect(ReceiptAiEnrichmentService).to have_received(:call)
    end

    it 'AI失敗fallbackではpayment_method_textが空でもPayments[]からpayment_methodを推定する' do
      ocr_result = build_ocr_result(
        raw_text: "サンプルストア\n2026/04/02 12:34\nコーヒー 180\n合計 1280",
        lines: [
          'サンプルストア',
          '2026/04/02 12:34',
          'コーヒー 180',
          '合計 1280'
        ],
        candidates: {
          payment_method_text: nil,
          payments: [
            { method: '現金', amount: 1280 }
          ]
        }
      )
      allow(ReceiptOcrService).to receive(:call).and_return(ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('analysis_missing_keys')
        expect(receipt.payment_method).to eq('cash')
        expect(receipt.receipt_payments.first.method).to eq('現金')
      end
    end

    it 'system reason only is stored in processing_error_code and not review_reasons' do
      allow(ReceiptOcrService).to receive(:call).and_return(build_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(
        failed_ai_result.merge(
          error_code: 'analysis_missing_keys',
          review_reasons: ['analysis_missing_keys']
        )
      )
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [],
          blocking_inconsistencies: [],
          warning_inconsistencies: []
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('analysis_missing_keys')
        expect(receipt.review_reasons).to be_blank
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

    it 'warning mismatch only stores amount warning review_reasons without review_needed status' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(candidates: { tip_amount: nil, tax_details: [] })
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [:price_tax_inclusion_uncertain],
          blocking_inconsistencies: [],
          warning_inconsistencies: [:price_tax_inclusion_uncertain]
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to eq(['price_tax_inclusion_uncertain'])
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

    it 'AI uncertainty stays in review_reasons' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(candidates: { tip_amount: nil, tax_details: [] })
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(
        successful_ai_result.merge(
          needs_review: true,
          review_reasons: ['item_name_uncertain']
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq(['item_name_uncertain'])
      end
    end

    it 'mixed mismatch stores blocking and warning amount review_reasons' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(candidates: { tip_amount: nil, tax_details: [] })
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)
      allow(ReceiptAmountService).to receive(:call).and_return(
        amount_result(
          inconsistencies: [:price_tax_inclusion_uncertain, :tax_detail_mismatch],
          blocking_inconsistencies: [:tax_detail_mismatch],
          warning_inconsistencies: [:price_tax_inclusion_uncertain]
        )
      )

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq(['tax_detail_mismatch', 'price_tax_inclusion_uncertain'])
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

    it 'OCR失敗時はAI downでもOCR失敗としてfailedになる' do
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
      allow(ExternalServiceStatus).to receive(:down?).with(:ai).and_return(true)
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_timeout')
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
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

    it 'OCR成功でもraw_text/linesが空なら no_text_detected でfailedにしAIを呼ばない' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: '',
          lines: [],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil,
            country_region: nil,
            receipt_type: nil,
            items: [],
            payments: [],
            tax_details: []
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('no_text_detected')
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      end
    end

    it '文字はあるが主要receipt signalsが不足する場合は receipt_not_detected でfailedにしAIを呼ばない' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: 'これはレシートではない文書です',
          lines: [ 'これはレシートではない文書です' ],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil,
            country_region: nil,
            receipt_type: nil,
            items: [],
            payments: [],
            tax_details: []
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('receipt_not_detected')
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      end
    end

    it 'CountryRegionとReceiptTypeだけではreceipt_not_detectedにしAIを呼ばない' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: '旅行メモ',
          lines: [ '旅行メモ' ],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil,
            country_region: 'JP',
            receipt_type: 'Meal',
            items: [],
            payments: [],
            tax_details: []
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('receipt_not_detected')
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      end
    end

    it 'docTypeがreceipt系でも主要fields不足ならreceipt_not_detectedにしAIを呼ばない' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: 'メモ画像',
          lines: [ 'メモ画像' ],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil,
            country_region: nil,
            receipt_type: nil,
            items: [],
            payments: [],
            tax_details: []
          },
          meta: {
            doc_type: 'receipt.retailMeal',
            confidence_summary: {
              items_average: nil,
              overall: 0.95
            }
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call)

      described_class.call(receipt)
      receipt.reload

      aggregate_failures do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('receipt_not_detected')
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      end
    end

    it 'TotalがあればAIへ進む' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: '合計 1280',
          lines: [ '合計 1280' ],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: 1280,
            payment_method_text: nil,
            country_region: nil,
            receipt_type: nil,
            items: [],
            payments: [],
            tax_details: []
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)

      expect(ReceiptAiEnrichmentService).to have_received(:call)
    end

    it 'ItemsがあればAIへ進む' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: 'コーヒー 180',
          lines: [ 'コーヒー 180' ],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil,
            country_region: nil,
            receipt_type: nil,
            items: [
              {
                raw_text: 'コーヒー',
                line_total: 180,
                confidence: 0.95
              }
            ],
            payments: [],
            tax_details: []
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)

      expect(ReceiptAiEnrichmentService).to have_received(:call)
    end

    it 'receipt語と金額らしき行があればAIへ進む' do
      allow(ReceiptOcrService).to receive(:call).and_return(
        build_ocr_result(
          raw_text: "領収書\n合計 1280",
          lines: [ '領収書', '合計 1280' ],
          candidates: {
            store_name: nil,
            purchased_at_text: nil,
            total_amount: nil,
            payment_method_text: nil,
            country_region: nil,
            receipt_type: nil,
            items: [],
            payments: [],
            tax_details: []
          }
        )
      )
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(successful_ai_result)

      described_class.call(receipt)

      expect(ReceiptAiEnrichmentService).to have_received(:call)
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

  describe 'OCR fixture regressions' do
    it '単一税率レシートはreview不要で金額を補正する' do
      amount = run_ocr_fixture('single_tax_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(1_080)
        expect(receipt.subtotal_amount).to eq(982)
        expect(receipt.tax_amount).to eq(98)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(receipt.receipt_tax_details.pluck(:net_amount, :amount, :rate)).to eq([[982, 98, BigDecimal('0.1')]])
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to be_empty
      end
    end

    it '複数税率レシートはreceipt.tax_rateをnilにし税内訳を保存する' do
      amount = run_ocr_fixture('multiple_tax_receipt')

      tax_details = receipt.receipt_tax_details.order(:rate)

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(218)
        expect(receipt.subtotal_amount).to eq(200)
        expect(receipt.tax_amount).to eq(18)
        expect(receipt.tax_rate).to be_nil
        expect(tax_details.map { |detail| [detail.net_amount, detail.amount, detail.rate] }).to eq([
          [100, 8, BigDecimal('0.08')],
          [100, 10, BigDecimal('0.1')]
        ])
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to be_empty
      end
    end

    it '外税レシートはtax_detailsを優先しreview不要にする' do
      amount = run_ocr_fixture('external_tax_receipt')

      tax_detail = receipt.receipt_tax_details.first

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(1_100)
        expect(receipt.subtotal_amount).to eq(1_000)
        expect(receipt.tax_amount).to eq(100)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(tax_detail.net_amount).to eq(1_000)
        expect(tax_detail.amount).to eq(100)
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to be_empty
      end
    end

    it 'OCRノイズ由来のocr_low_confidenceはwarningとして扱いreview不要にする' do
      amount = run_ocr_fixture(
        'ocr_noise_receipt',
        ai_result: ai_success_result_for(
          ocr_fixture('ocr_noise_receipt'),
          review_reasons: ['ocr_low_confidence']
        )
      )

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to eq(['ocr_low_confidence'])
        expect(receipt.total_amount).to eq(110)
        expect(receipt.subtotal_amount).to eq(100)
        expect(receipt.tax_amount).to eq(10)
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to be_empty
      end
    end

    it 'subtotal欠損レシートは明細計算でsubtotal/taxを補完する' do
      amount = run_ocr_fixture('missing_subtotal_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_blank
        expect(receipt.total_amount).to eq(999)
        expect(receipt.subtotal_amount).to eq(909)
        expect(receipt.tax_amount).to eq(90)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(amount[:needs_review]).to be(false)
        expect(amount[:mismatch_codes]).to be_empty
      end
    end

    it 'Azure Totalがお預かり金額でも明細合計でtotalを補正する' do
      amount = run_ocr_fixture('deposit_total_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to include('ocr_total_mismatch', 'price_tax_inclusion_uncertain')
        expect(receipt.total_amount).to eq(2_204)
        expect(receipt.total_amount).not_to eq(5_000)
        expect(receipt.subtotal_amount).to eq(2_004)
        expect(receipt.tax_amount).to eq(200)
        expect(amount[:needs_review]).to be(false)
        expect(amount[:blocking_inconsistencies]).to be_empty
      end
    end

    it 'tax_detailsと明細が矛盾するレシートはblocking mismatchでreview_neededにする' do
      amount = run_ocr_fixture('tax_detail_item_conflict_receipt')

      aggregate_failures do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('tax_detail_mismatch')
        expect(receipt.total_amount).to eq(108)
        expect(receipt.subtotal_amount).to eq(99)
        expect(receipt.tax_amount).to eq(9)
        expect(amount[:needs_review]).to be(true)
        expect(amount[:blocking_inconsistencies]).to include(:tax_detail_mismatch)
        expect(amount[:warning_inconsistencies]).to include(:ocr_total_mismatch)
        expect(amount[:mismatch_codes]).to include('TAX_DETAIL_MISMATCH')
      end
    end
  end
end
