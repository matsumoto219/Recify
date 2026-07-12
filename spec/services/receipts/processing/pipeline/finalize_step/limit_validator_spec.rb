require 'rails_helper'

RSpec.describe Receipts::Processing::Pipeline::FinalizeStep::LimitValidator do
  subject(:validator) { described_class.new(receipt: receipt) }

  let(:receipt) { instance_double(Receipt, receipt_items_limit: 2) }

  before do
    allow(ReceiptAdjustment).to receive(:per_receipt_limit).and_return(2)
    allow(ReceiptPayment).to receive(:per_receipt_limit).and_return(2)
    allow(ReceiptTaxDetail).to receive(:per_receipt_limit).and_return(2)
  end

  describe '#validate_source_structural_limits!' do
    it 'uses the original count metadata even when the OCR snapshot collection is truncated' do
      ocr_result = {
        'candidate_counts' => {
          'items' => { 'actual_count' => '3', 'snapshot_count' => '1' }
        },
        'candidates' => {
          'items' => [ { 'raw_text' => 'snapshot item' } ]
        }
      }
      original = ocr_result.deep_dup

      expect {
        validator.validate_source_structural_limits!(ocr_result: ocr_result)
      }.to raise_error(Receipts::Processing::AnalysisError, 'receipt_items_limit_exceeded count=3 limit=2') { |error|
        aggregate_failures do
          expect(error.error_code).to eq('analysis_items_invalid')
          expect(error.metadata).to eq(
            error: 'analysis_items_invalid',
            resource: 'receipt_items',
            limit: 2,
            actual_count: 3,
            snapshot_count: 1
          )
        end
      }

      expect(ocr_result).to eq(original)
    end

    it 'falls back to the OCR collection size when count metadata is invalid' do
      allow(ReceiptPayment).to receive(:per_receipt_limit).and_return(1)
      ocr_result = {
        candidate_counts: {
          payments: { actual_count: 'invalid', snapshot_count: '1' }
        },
        candidates: {
          payments: [ { method: 'Cash' }, { method: 'CreditCard' } ]
        }
      }

      expect {
        validator.validate_source_structural_limits!(ocr_result: ocr_result)
      }.to raise_error(Receipts::Processing::AnalysisError, 'receipt_payments_limit_exceeded count=2 limit=1') { |error|
        aggregate_failures do
          expect(error.error_code).to eq('analysis_value_invalid')
          expect(error.metadata).to eq(
            error: 'analysis_value_invalid',
            resource: 'receipt_payments',
            limit: 1,
            actual_count: 2,
            snapshot_count: 2
          )
        end
      }
    end

    it 'uses AI attribute counts for adjustments without changing the input' do
      allow(ReceiptAdjustment).to receive(:per_receipt_limit).and_return(1)
      ocr_result = { candidates: {} }
      ai_result = {
        'attribute_counts' => {
          'receipt_adjustments_attributes' => { 'actual_count' => '2', 'snapshot_count' => '1' }
        },
        'receipt_adjustments_attributes' => [ { 'amount' => 100 } ]
      }
      original = ai_result.deep_dup

      expect {
        validator.validate_source_structural_limits!(ocr_result: ocr_result, ai_result: ai_result)
      }.to raise_error(Receipts::Processing::AnalysisError, 'receipt_adjustments_limit_exceeded count=2 limit=1') { |error|
        expect(error.metadata).to eq(
          error: 'analysis_value_invalid',
          resource: 'receipt_adjustments',
          limit: 1,
          actual_count: 2,
          snapshot_count: 1
        )
      }

      expect(ai_result).to eq(original)
    end
  end

  describe '#validate_structural_limits!' do
    let(:params) do
      {
        receipt_items_attributes: [ {}, {} ],
        receipt_adjustments_attributes: [ {}, {} ],
        receipt_payments_attributes: [ {}, {} ],
        receipt_tax_details_attributes: [ {}, {} ]
      }
    end

    it 'allows every collection at its exact limit without changing the input' do
      original = params.deep_dup

      expect { validator.validate_structural_limits!(params) }.not_to raise_error
      expect(params).to eq(original)
    end

    it 'reads the receipt item limit again at every validation boundary' do
      allow(receipt).to receive(:receipt_items_limit).and_return(1, 2)

      expect {
        validator.validate_structural_limits!(params.merge(receipt_items_attributes: [ {} ]))
        validator.validate_structural_limits!(params)
      }.not_to raise_error
      expect(receipt).to have_received(:receipt_items_limit).twice
    end
  end

  describe '#validate_amount_limits!' do
    it 'raises from the first amount violation with the existing metadata shape' do
      attributes = {
        receipt_attributes: { total_amount: 100 },
        items_attributes: [ { line_total: 501 } ],
        adjustments_attributes: [],
        payments_attributes: [],
        tax_details_attributes: []
      }
      original = attributes.deep_dup
      allow(ReceiptAmountService).to receive(:violations_for).and_return(
        [
          {
            resource: 'receipt_items',
            field: 'line_total',
            limit: 500,
            actual_value: 501,
            index: 0
          },
          {
            resource: 'receipt',
            field: 'total_amount',
            limit: 99,
            actual_value: 100
          }
        ]
      )

      expect {
        validator.validate_amount_limits!(**attributes)
      }.to raise_error(
        Receipts::Processing::AnalysisError,
        'receipt_items_amount_limit_exceeded field=line_total actual=501 limit=500'
      ) { |error|
        aggregate_failures do
          expect(error.error_code).to eq('analysis_value_invalid')
          expect(error.metadata).to eq(
            error: 'analysis_value_invalid',
            resource: 'receipt_items',
            field: 'line_total',
            limit: 500,
            actual_value: 501,
            index: 0
          )
        end
      }

      expect(attributes).to eq(original)
    end
  end
end
