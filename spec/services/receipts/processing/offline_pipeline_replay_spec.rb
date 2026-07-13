require 'rails_helper'
require 'webmock/rspec'
require_relative '../../../../tools/generated_receipts'

RSpec.describe 'Receipt processing offline pipeline replay' do
  SECRET_SENTINEL = 'offline-secret-sentinel-do-not-store'
  SNAPSHOT_ATTRIBUTES = %w[
    ocr_summary
    ocr_result_snapshot
    ai_input_snapshot
    ai_result_summary
    ai_normalized_result_snapshot
    final_result_summary
    metadata
  ].freeze
  FORBIDDEN_SNAPSHOT_KEYS = %w[
    api_key
    authorization
    blob_key
    client_secret
    cookie
    cookies
    full_prompt
    headers
    image
    image_payload
    messages
    password
    prompt
    prompt_text
    provider_raw_response
    raw_response
    response_body
    secret
    signed_id
    token
  ].freeze

  OFFLINE_CASES = [
    {
      fixture: 'single_tax_receipt',
      payment_method: 'cash',
      status: 'completed',
      subtotal: 700,
      tax: 70,
      total: 770,
      tax_rate: BigDecimal('0.1'),
      item_count: 4,
      adjustment_count: 0,
      payment_count: 0,
      payment_sum: 0,
      tax_detail_count: 1,
      item_rows: [
        [ 'ノート A5', 1, 220, 220, 220, nil, BigDecimal('0.1') ],
        [ 'ボールペン(黒)', 1, 132, 132, 132, nil, BigDecimal('0.1') ],
        [ 'クリアファイル A4', 1, 110, 110, 110, nil, BigDecimal('0.1') ],
        [ '修正テープ', 1, 308, 308, 308, nil, BigDecimal('0.1') ]
      ],
      adjustment_rows: [],
      payment_rows: [],
      tax_detail_rows: [ [ '10%対象', 700, 70, BigDecimal('0.1') ] ],
      review_reasons: []
    },
    {
      fixture: 'multiple_tax_receipt',
      payment_method: 'cash',
      status: 'completed',
      subtotal: 1_598,
      tax: 134,
      total: 1_732,
      tax_rate: nil,
      item_count: 6,
      adjustment_count: 0,
      payment_count: 1,
      payment_sum: 1_732,
      tax_detail_count: 2,
      item_rows: [
        [ 'たまご Mサイズ 10個入', 1, 198, 198, 198, nil, BigDecimal('0.08') ],
        [ '牛乳 1000ml', 1, 248, 248, 248, nil, BigDecimal('0.08') ],
        [ '食パン 6枚切', 1, 158, 158, 158, nil, BigDecimal('0.08') ],
        [ 'トイレットペーパー12R', 1, 398, 398, 398, nil, BigDecimal('0.1') ],
        [ '洗濯用洗剤 液体 900g', 1, 298, 298, 298, nil, BigDecimal('0.1') ],
        [ 'シャンプー 詰替 330ml', 1, 298, 298, 298, nil, BigDecimal('0.1') ]
      ],
      adjustment_rows: [],
      payment_rows: [ [ 'cash', 1_732 ] ],
      tax_detail_rows: [
        [ '8%対象', 604, 44, BigDecimal('0.08') ],
        [ '10%対象', 994, 90, BigDecimal('0.1') ]
      ],
      review_reasons: []
    },
    {
      fixture: 'discount_heavy_receipt',
      payment_method: 'credit_card',
      status: 'completed',
      subtotal: 529,
      tax: 42,
      total: 571,
      tax_rate: BigDecimal('0.08'),
      item_count: 4,
      adjustment_count: 3,
      payment_count: 2,
      payment_sum: 571,
      tax_detail_count: 1,
      item_rows: [
        [ '国産豚こま切れ肉 200g', 1, 398, 348, 398, 50, BigDecimal('0.08') ],
        [ 'きゅうり 1本', 1, 258, 258, 258, nil, BigDecimal('0.08') ],
        [ "トマト (大玉)\n1個", 1, 198, 198, 198, nil, BigDecimal('0.08') ],
        [ 'たまご Mサイズ 6個入', 1, 128, 98, 128, 30, BigDecimal('0.08') ]
      ],
      adjustment_rows: [
        [ 'receipt_discount', 100, 'discount' ],
        [ 'coupon', 200, 'discount' ],
        [ 'receipt_discount', 31, 'discount' ]
      ],
      payment_rows: [ [ 'ポイント利用', 300 ], [ 'クレジットカード', 271 ] ],
      tax_detail_rows: [ [ '8%対象', 529, 42, BigDecimal('0.08') ] ],
      review_reasons: []
    },
    {
      fixture: 'tax_detail_item_conflict_receipt',
      payment_method: 'qr_payment',
      status: 'review_needed',
      subtotal: 977,
      tax: 22,
      total: 999,
      tax_rate: BigDecimal('0.08'),
      item_count: 2,
      adjustment_count: 0,
      payment_count: 1,
      payment_sum: 999,
      tax_detail_count: 2,
      item_rows: [
        [ 'カフェラテ(500ml)', 1, 120, 120, 120, nil, nil ],
        [ 'チョコチップクッキー', 1, 159, 159, 159, nil, nil ]
      ],
      adjustment_rows: [],
      payment_rows: [ [ 'paypay支払', 999 ] ],
      tax_detail_rows: [
        [ '小 計(税抜 8%) / 消費税等(8%) / 消費税等', 279, 22, BigDecimal('0.08') ],
        [ '消費税等(10%) / 消費税等', 0, 54, BigDecimal('0.1') ]
      ],
      required_review_reasons: %w[tax_detail_mismatch]
    },
    {
      fixture: 'item_owned_bag_quantity_receipt',
      generated_case: 'g112_item_owned_bag_quantity',
      payment_method: 'e_money',
      status: 'completed',
      subtotal: 742,
      tax: 59,
      total: 801,
      tax_rate: nil,
      item_count: 2,
      adjustment_count: 0,
      payment_count: 1,
      payment_sum: 801,
      tax_detail_count: 2,
      item_rows: [
        [ 'サンプル軽減商品A', 1, 798, 798, 798, nil, BigDecimal('0.08') ],
        [ 'レジ袋中1枚', 1, 3, 3, 3, nil, BigDecimal('0.1') ]
      ],
      adjustment_rows: [],
      payment_rows: [ [ '電子マネー支払', 801 ] ],
      tax_detail_rows: [
        [ '8%対象', 739, 59, BigDecimal('0.08') ],
        [ '10%対象', 3, 0, BigDecimal('0.1') ]
      ],
      review_reasons: [],
      ai_item_names: [ 'サンプル軽減商品A', 'レジ袋中1枚' ],
      ai_item_categories: %w[food daily_goods],
      ai_receipt_attributes: {
        store_name: 'サンプル検証ストア'
      },
      ai_adjustments: [
        {
          kind: 'bag_fee',
          label: 'レジ袋中1枚',
          amount: 3,
          sign: 'discount',
          source_text: 'レジ袋中1枚',
          source_line_index: 4,
          confidence: BigDecimal('0.9'),
          needs_review: false,
          review_reasons: []
        }
      ]
    },
    {
      fixture: 'missing_store_name_and_purchased_at_receipt',
      real_receipt_replay: true,
      payment_method: 'e_money',
      status: 'review_needed',
      subtotal: 742,
      tax: 59,
      total: 801,
      tax_rate: nil,
      item_count: 5,
      adjustment_count: 0,
      payment_count: 1,
      payment_sum: 801,
      tax_detail_count: 2,
      item_rows: [
        [ 'サンプル軽減商品A', 1, 128, 128, 128, nil, BigDecimal('0.08') ],
        [ 'サンプル軽減商品B', 1, 198, 198, 198, nil, BigDecimal('0.08') ],
        [ 'サンプル軽減商品C', 1, 115, 115, 115, nil, BigDecimal('0.08') ],
        [ 'サンプル軽減商品D', 1, 298, 298, 298, nil, BigDecimal('0.08') ],
        [ 'レジ袋中1枚', 1, 3, 3, 3, nil, BigDecimal('0.1') ]
      ],
      adjustment_rows: [],
      payment_rows: [ [ 'Suica支払', 801 ] ],
      tax_detail_rows: [
        [ '8%対象', 739, 59, BigDecimal('0.08') ],
        [ '10%対象', 3, 0, BigDecimal('0.1') ]
      ],
      required_review_reasons: %w[store_name_missing purchased_at_missing]
    }
  ].freeze

  around do |example|
    WebMock.disable_net_connect!(allow_localhost: true)
    example.run
  ensure
    WebMock.allow_net_connect!
  end

  OFFLINE_CASES.each do |case_config|
    it "replays #{case_config.fetch(:fixture)} through parser, snapshots, amount, persistence, and terminal state" do
      execution = replay_case(case_config)
      receipt = execution.fetch(:receipt)
      run = execution.fetch(:run)
      ocr_result = execution.fetch(:ocr_result)

      verify_receipt_result(receipt, case_config)
      verify_child_records(receipt, case_config)
      verify_terminal_run(run, receipt, case_config)
      verify_item_source_values(receipt, ocr_result)
      verify_ownership_contract(run)
      verify_safe_snapshots(run)

      verify_generated_case(receipt, case_config.fetch(:generated_case)) if case_config[:generated_case]
      verify_real_receipt_replay(receipt) if case_config[:real_receipt_replay]
    end
  end

  def replay_case(case_config)
    raw_response = JSON.parse(
      Rails.root.join("spec/fixtures/ocr/#{case_config.fetch(:fixture)}.json").read
    )
    raw_response['authorization'] = SECRET_SENTINEL
    stub_ocr_client(raw_response)
    stub_ai_client(ai_result_for(case_config))

    receipt = create(:receipt, :processing, :with_image)
    run = Receipts::Processing.start(receipt: receipt, source: 'upload').run

    ocr_execution = Receipts::Processing.run_ocr(run)
    expect(ocr_execution.next_step).to eq(:ai)
    expect(ocr_execution.ocr_result.dig(:candidates, :items).size).to eq(case_config.fetch(:item_count))

    ai_execution = Receipts::Processing.run_ai(
      run: run,
      ocr_result: ocr_execution.ocr_result
    )
    expect(ai_execution.next_step).to eq(:finalize)

    finalize_execution = Receipts::Processing.run_finalize(run)
    expect(finalize_execution.next_step).to eq(:done)

    {
      receipt: receipt.reload,
      run: run.reload,
      ocr_result: ocr_execution.ocr_result
    }
  end

  def stub_ocr_client(raw_response)
    allow(Ocr::Client).to receive(:new) do |**options|
      client = instance_double(Ocr::Client)
      allow(client).to receive(:call) do
        options[:before_provider_call]&.call
        raw_response.deep_dup
      end
      client
    end
  end

  def stub_ai_client(ai_result)
    allow(Ai::Client).to receive(:new) do |**_options|
      client = instance_double(Ai::Client)
      allow(client).to receive(:call) do |_input, before_provider_call: nil|
        before_provider_call&.call
        ai_result.deep_dup
      end
      client
    end
  end

  def ai_result_for(case_config)
    item_names = Array(case_config[:ai_item_names])
    item_categories = Array(case_config[:ai_item_categories])
    items = Array.new(case_config.fetch(:item_count)) do |index|
      {
        index: index,
        suggested_name: item_names[index],
        category: item_categories[index] || 'other',
        needs_review: false
      }.compact
    end

    {
      success: true,
      needs_review: false,
      review_reasons: [],
      receipt_attributes: {
        payment_method: case_config.fetch(:payment_method)
      }.merge(case_config.fetch(:ai_receipt_attributes, {})),
      receipt_items_attributes: items,
      receipt_adjustments_attributes: Array(case_config[:ai_adjustments]),
      meta: {
        provider: 'offline_fixture',
        api_key: SECRET_SENTINEL
      }
    }
  end

  def verify_receipt_result(receipt, case_config)
    aggregate_failures 'receipt and children' do
      expect(receipt.status).to eq(case_config.fetch(:status))
      expect(receipt.processing_error_code).to be_nil
      expect(receipt.subtotal_amount).to eq(case_config.fetch(:subtotal))
      expect(receipt.tax_amount).to eq(case_config.fetch(:tax))
      expect(receipt.total_amount).to eq(case_config.fetch(:total))
      expect(receipt.tax_rate).to eq(case_config[:tax_rate])
      expect(receipt.payment_method).to eq(case_config.fetch(:payment_method))
      expect(receipt.receipt_items.count).to eq(case_config.fetch(:item_count))
      expect(receipt.receipt_adjustments.count).to eq(case_config.fetch(:adjustment_count))
      expect(receipt.receipt_payments.count).to eq(case_config.fetch(:payment_count))
      expect(receipt.receipt_payments.sum(:amount)).to eq(case_config.fetch(:payment_sum))
      expect(receipt.receipt_tax_details.count).to eq(case_config.fetch(:tax_detail_count))
    end

    if case_config.key?(:review_reasons)
      expect(Array(receipt.review_reasons).sort).to eq(case_config.fetch(:review_reasons).sort)
    else
      expect(receipt.review_reasons).to include(*case_config.fetch(:required_review_reasons))
    end
  end

  def verify_child_records(receipt, case_config)
    aggregate_failures 'persisted child values' do
      expect(receipt.receipt_items.order(:position_index, :id).pluck(
        :raw_text,
        :quantity,
        :price,
        :line_total,
        :original_line_total,
        :discount_amount,
        :tax_rate
      )).to eq(case_config.fetch(:item_rows))
      expect(receipt.receipt_adjustments.order(:position_index, :id).pluck(:kind, :amount, :sign)).to eq(
        case_config.fetch(:adjustment_rows)
      )
      expect(receipt.receipt_payments.order(:id).pluck(:method, :amount)).to eq(
        case_config.fetch(:payment_rows)
      )
      expect(receipt.receipt_tax_details.order(:rate, :id).pluck(
        :description,
        :net_amount,
        :amount,
        :rate
      )).to eq(case_config.fetch(:tax_detail_rows))
    end
  end

  def verify_terminal_run(run, receipt, case_config)
    aggregate_failures 'run terminal contract' do
      expect(run.status).to eq('succeeded')
      expect(run.stage).to eq('completed')
      expect(run.error_code).to be_nil
      expect(run.ocr_result_snapshot).to include('success' => true)
      expect(run.ai_normalized_result_snapshot).to include('success' => true)
      expect(run.final_result_summary).to include(
        'receipt_status' => case_config.fetch(:status),
        'item_count' => receipt.receipt_items.count,
        'payment_count' => receipt.receipt_payments.count,
        'tax_detail_count' => receipt.receipt_tax_details.count,
        'adjustment_count' => receipt.receipt_adjustments.count
      )
    end
  end

  def verify_item_source_values(receipt, ocr_result)
    expected_raw_texts = Array(ocr_result.dig(:candidates, :items)).map do |item|
      item.with_indifferent_access[:raw_text]
    end
    saved_items = receipt.receipt_items.order(:position_index, :id)

    aggregate_failures 'OCR and user-owned item fields' do
      expect(saved_items.pluck(:raw_text)).to eq(expected_raw_texts)
      expect(saved_items.pluck(:confirmed_name)).to all(be_nil)
    end
  end

  def verify_ownership_contract(run)
    contract = run.metadata.dig('build_params_snapshot', 'ownership_contract')

    expect(contract).to include(
      'duplicate_source_owner_count' => 0,
      'payment_source_purchase_adjustment_count' => 0,
      'tax_detail_source_effect_count' => 0
    )
  end

  def verify_safe_snapshots(run)
    snapshots = run.attributes.slice(*SNAPSHOT_ATTRIBUTES)
    snapshot_json = JSON.generate(snapshots)
    forbidden_keys = deep_keys(snapshots) & FORBIDDEN_SNAPSHOT_KEYS

    aggregate_failures 'safe snapshots' do
      expect(snapshot_json).not_to include(SECRET_SENTINEL)
      expect(forbidden_keys).to be_empty
    end
  end

  def deep_keys(value)
    case value
    when Hash
      value.flat_map do |key, child|
        [ key.to_s, *deep_keys(child) ]
      end
    when Array
      value.flat_map { |child| deep_keys(child) }
    else
      []
    end
  end

  def verify_generated_case(receipt, case_id)
    case_data = GeneratedReceipts::Validator.load_file(
      File.join(GeneratedReceipts::CASES_DIR, "#{case_id}.json")
    )
    actual = GeneratedReceipts::Comparator.snapshot_from_receipt(receipt)
    comparison = GeneratedReceipts::Comparator.call(case_data, actual)

    expect(comparison.status).to eq('PASS'), -> { comparison.diffs.inspect }
  end

  def verify_real_receipt_replay(receipt)
    aggregate_failures 'anonymized real receipt 001' do
      expect(receipt.store_name).to be_nil
      expect(receipt.purchased_at).to be_nil
      expect(receipt.status).to eq('review_needed')
      expect(receipt.review_reasons).to include('store_name_missing', 'purchased_at_missing')
    end
  end
end
