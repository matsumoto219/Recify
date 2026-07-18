require 'rails_helper'

RSpec.describe ReceiptAmountService do
  def call_service(receipt:, receipt_items: [], receipt_tax_details: [], receipt_adjustments: [], receipt_payments: [], context: :analysis, rounding_mode: nil, tax_rounding_mode: nil, discount_rounding_mode: nil)
    kwargs = {
      receipt: receipt,
      receipt_items: receipt_items,
      receipt_tax_details: receipt_tax_details,
      receipt_adjustments: receipt_adjustments,
      receipt_payments: receipt_payments,
      context: context
    }
    kwargs[:rounding_mode] = rounding_mode if rounding_mode
    kwargs[:tax_rounding_mode] = tax_rounding_mode if tax_rounding_mode
    kwargs[:discount_rounding_mode] = discount_rounding_mode if discount_rounding_mode

    described_class.call(**kwargs)
  end

  describe '.calculation_profile_snapshot' do
    it 'amount calculation resultから保存用snapshotを返す' do
      result = {
        context: :manual,
        rounding_mode: { tax: :floor, discount: :round },
        computed: { subtotal: 100, tax: 10, total: 110 },
        resolved: { subtotal: 100, tax: 10, total: 110 },
        mismatch_codes: [ 'TOTAL_MISMATCH' ],
        blocking_mismatch_codes: [ 'TOTAL_MISMATCH' ],
        warning_mismatch_codes: []
      }

      snapshot = described_class.calculation_profile_snapshot(result)

      aggregate_failures do
        expect(snapshot[:context]).to eq('manual')
        expect(snapshot[:computed]).to eq(
          total_amount: 110,
          subtotal_amount: 100,
          tax_amount: 10
        )
        expect(snapshot[:mismatch_codes]).to eq([ 'TOTAL_MISMATCH' ])
      end
    end
  end

  describe '.parse_amount_or_nil' do
    it '金額文字列をBigDecimalへ正規化する' do
      expect(described_class.parse_amount_or_nil('1,234円')).to eq(BigDecimal('1234'))
    end

    it '空文字はnilを返す' do
      expect(described_class.parse_amount_or_nil('')).to be_nil
    end
  end

  describe '.parse_amount' do
    it '金額文字列をIntegerへ正規化する' do
      expect(described_class.parse_amount('1,234円')).to eq(1234)
    end

    it '不正値はdefaultを返す' do
      expect(described_class.parse_amount('不明', default: 0)).to eq(0)
    end
  end

  describe '.parse_quantity' do
    it '数量文字列をBigDecimalへ正規化する' do
      expect(described_class.parse_quantity('2.5')).to eq(BigDecimal('2.5'))
    end

    it '不正値はdefaultを返す' do
      expect(described_class.parse_quantity('不明', default: BigDecimal('1'))).to eq(BigDecimal('1'))
    end
  end

  describe 'amount limit facade' do
    it 'exposes configured limits through the Amount Engine public entry point' do
      aggregate_failures do
        expect(described_class.receipt_total_amount_max).to eq(999_999_999)
        expect(described_class.receipt_item_price_max).to eq(999_999_999)
        expect(described_class.receipt_item_line_total_max).to eq(999_999_999)
        expect(described_class.receipt_tax_amount_max).to eq(999_999_999)
        expect(described_class.receipt_adjustment_amount_max).to eq(999_999_999)
        expect(described_class.receipt_payment_amount_max).to eq(999_999_999)
      end
    end

    it 'exposes the existing amount-limit violation shape unchanged' do
      expect(described_class.violations_for(receipt: { total_amount: 1_000_000_000 })).to contain_exactly(
        resource: 'receipt',
        field: 'total_amount',
        limit: 999_999_999,
        actual_value: 1_000_000_000
      )
    end
  end

  describe '.call' do
    it 'analysisでは評価済みcandidateを再利用し候補生成を二重実行しない' do
      expect(Amounts::CandidateGenerator).to receive(:new).once.and_call_original

      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100
        },
        receipt_items: [
          { line_total: 1_100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        receipt_payments: [
          { method: 'cash', amount: 1_100 }
        ],
        context: :analysis
      )

      expect(result[:resolved]).to include(total: 1_100)
    end

    it 'defaults rounding_mode to floor' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
      end
    end

    it 'accepts rounding_mode and applies ceil to representative tax calculation' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        rounding_mode: :ceil
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(98)
        expect(result[:resolved][:tax]).to eq(10)
      end
    end

    it 'defaultではnative engine候補で通常税込明細を税抜候補へ寄せない' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') }
        ]
      )

      aggregate_failures do
        # 検算: 税込108円、8%内税は floor(108 * 8 / 108) = 8円。税抜100円、購入合計108円。
        expect(result[:resolved]).to include(subtotal: 100, tax: 8, total: 108)
        expect(result.dig(:amount_engine, :selected_basis)).to eq('items_as_tax_included')
        expect(result.dig(:amount_engine, :selected_candidate_id)).to start_with('items_as_tax_included/')
      end
    end

    it 'native engineでもpriceとcountable quantityからline_totalを補完する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 250, quantity: 2, quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0') }
        ]
      )

      item = result.dig(:computed, :items).first

      aggregate_failures do
        # 検算: 250円 x 2個 = 500円。税率0%なのでsubtotal/tax/totalは500/0/500。
        expect(item[:quantity]).to eq(BigDecimal('2'))
        expect(item[:original_line_total]).to eq(500)
        expect(item[:line_total]).to eq(500)
        expect(result[:resolved]).to include(subtotal: 500, tax: 0, total: 500)
      end
    end

    it 'native engineではquantity_unit_codeを保持して金額計算する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 250, quantity: 2, quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0') }
        ]
      )

      item = result.dig(:computed, :items).first

      aggregate_failures do
        expect(item[:quantity_unit_code]).to eq('each')
        expect(item[:line_total]).to eq(500)
        expect(result[:resolved]).to include(subtotal: 500, tax: 0, total: 500)
      end
    end

    it 'native engineでもnil/0 quantityを1として扱う' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 250, quantity: nil, quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0') },
          { price: 300, quantity: 0, quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0') }
        ]
      )

      items = result.dig(:computed, :items)

      aggregate_failures do
        # 検算: nil quantityは1、0 quantityも1へ正規化。250 + 300 = 550円。
        expect(items.map { |item| item[:quantity] }).to eq([ BigDecimal('1'), BigDecimal('1') ])
        expect(items.map { |item| item[:line_total] }).to eq([ 250, 300 ])
        expect(result[:resolved]).to include(subtotal: 550, tax: 0, total: 550)
      end
    end

    it 'native engineではmeasurement unitのline_total欠落を補完せず未知単位はdefault codeへ整理する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: nil, tax_rate: BigDecimal('0') },
          { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0') }
        ]
      )

      items = result.dig(:computed, :items)

      aggregate_failures do
        # 検算: kgはmeasurementのため補完しない。候補外の束は保存せずdefault eachへ整理する。
        expect(items.map { |item| item[:line_total] }).to eq([ 0, 4_320 ])
        expect(result[:resolved]).to include(subtotal: 4_320, tax: 0, total: 4_320)
      end
    end

    it 'native engineでもmeasurement unitの明示line_totalは保持する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: 4_320, tax_rate: BigDecimal('0') }
        ]
      )

      item = result.dig(:computed, :items).first

      aggregate_failures do
        # 検算: 重量単価からの自動補完はしないが、明示line_total 4,320円は正として保持する。
        expect(item[:quantity]).to eq(BigDecimal('0.300'))
        expect(item[:line_total]).to eq(4_320)
        expect(result[:resolved]).to include(subtotal: 4_320, tax: 0, total: 4_320)
      end
    end

    it 'native engineでもmanualのdiscount_rateからdiscount_amountとline_totalを正規化する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 999, quantity: 1, quantity_unit_code: 'each', discount_rate: BigDecimal('0.105'), line_total: nil, tax_rate: BigDecimal('0') }
        ],
        context: :manual
      )

      item = result.dig(:computed, :items).first

      aggregate_failures do
        # 検算: 999 x 10.5% = 104.895。discount rounding roundで105円、999 - 105 = 894円。
        expect(item[:original_line_total]).to eq(999)
        expect(item[:discount_amount]).to eq(105)
        expect(item[:line_total]).to eq(894)
        expect(result[:resolved]).to include(subtotal: 894, tax: 0, total: 894)
      end
    end

    it 'analysisではdiscount_rounding_modeを候補化しreceipt totalに合う候補を採用する' do
      result = call_service(
        receipt: {
          total_amount: 135
        },
        receipt_items: [
          {
            price: 271,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: nil,
            discount_rate: BigDecimal('0.5'),
            tax_rate: BigDecimal('0')
          }
        ],
        context: :analysis
      )

      item = result.dig(:computed, :items).first

      aggregate_failures do
        # 検算: 271円の50%引き。round/ceilは割引136円で残額135円、floorは割引135円で残額136円。
        expect(result[:resolved]).to include(subtotal: 135, tax: 0, total: 135)
        expect(item[:discount_amount]).to eq(136)
        expect(item[:line_total]).to eq(135)
        expect(result.dig(:computed, :amount_engine_candidate_id)).to start_with('items_as_tax_included/')
      end
    end

    it 'native engineでもdiscount_amountはoriginal_line_totalから差し引く' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 300, quantity: 2, quantity_unit_code: 'each', original_line_total: 600, discount_amount: 300, line_total: 300, tax_rate: BigDecimal('0') }
        ]
      )

      item = result.dig(:computed, :items).first

      aggregate_failures do
        # 検算: 割引前600円 - 割引300円 = 割引後line_total 300円。
        expect(item[:original_line_total]).to eq(600)
        expect(item[:discount_amount]).to eq(300)
        expect(item[:line_total]).to eq(300)
        expect(result[:resolved]).to include(subtotal: 300, tax: 0, total: 300)
      end
    end

    it 'native engineでも割引なしの税込補正済みline_totalはstale original_line_totalより優先する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 140, quantity: 1, quantity_unit_code: 'each', original_line_total: 130, line_total: 140, tax_rate: BigDecimal('0') }
        ],
        context: :manual
      )

      item = result.dig(:computed, :items).first

      aggregate_failures do
        # 検算: 130円はOCR元値。手動/編集保存では税込補正済みの140円を現在入力として正にする。
        expect(item[:original_line_total]).to eq(140)
        expect(item[:line_total]).to eq(140)
        expect(result[:resolved]).to include(subtotal: 140, tax: 0, total: 140)
      end
    end

    it 'native engineでもmanualのtotalのみ入力を保持する' do
      result = call_service(
        receipt: { total_amount: 1_100 },
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        # 検算: 明細なし、入力はtotal 1,100のみ。現行Resolver同様subtotal/taxはfallback 0、totalは入力値を保持。
        expect(result[:resolved]).to include(subtotal: 0, tax: 0, total: 1_100, tax_rate: nil)
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('manual_receipt_input')
      end
    end

    it 'native engineでもmanualのsubtotal/tax/total入力を保持する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        # 検算: 1,000 + 100 = 1,100。入力済みtax_rate 10%も保持する。
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: BigDecimal('0.1'))
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('manual_receipt_input')
      end
    end

    it 'subtotalとtaxの合計がtotalに一致しないreceipt inputを自動完了候補にしない' do
      result = call_service(
        receipt: {
          subtotal_amount: 100,
          tax_amount: 100,
          total_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.1') }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 91, tax: 9, total: 100)
        expect(result[:review_reasons]).to include('invalid_amount_relation')
        expect(result[:safe_to_auto_complete]).to be(false)
      end
    end

    it '課税明細があるtotal-only receipt inputで税額を0へ消さない' do
      result = call_service(
        receipt: { total_amount: 100 },
        receipt_items: [
          { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0.1') }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 91, tax: 9, total: 100)
        expect(result[:review_reasons]).to include('invalid_amount_relation')
        expect(result[:safe_to_auto_complete]).to be(false)
      end
    end

    it 'native engineでもmanualのtax 0をnilと区別して保持する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_100,
          tax_amount: 0,
          total_amount: 1_100,
          tax_rate: 0
        },
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        # 検算: 1,100 + 0 = 1,100。tax/tax_rateは明示0として保持する。
        expect(result[:resolved]).to include(subtotal: 1_100, tax: 0, total: 1_100, tax_rate: BigDecimal('0'))
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('manual_receipt_input')
      end
    end

    it 'native engineでもmanualのtax nilはsubtotal/totalから補完する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: nil,
          total_amount: 1_100
        },
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        # 検算: tax未入力だがsubtotal 1,000 / total 1,100があるため差額100円をtax候補にする。
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: nil)
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('manual_receipt_input')
      end
    end

    it 'native engineでもedit_saveの保存済み金額を保持する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :edit_save
      )

      aggregate_failures do
        # 検算: edit_save明細なしでは保存済み 1,000 + 100 = 1,100 を保持する。
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: BigDecimal('0.1'))
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('edit_saved_input')
      end
    end

    it 'native engineでは明細と入力金額が一致するmanual入力候補を採用できる' do
      result = call_service(
        receipt: {
          subtotal_amount: 500,
          tax_amount: 0,
          total_amount: 500,
          tax_rate: 0
        },
        receipt_items: [
          { price: 250, quantity: 2, quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0') }
        ],
        context: :manual
      )

      aggregate_failures do
        # 検算: 明細 250 x 2 = 500。入力金額とも一致するためmanual_receipt_inputが採用可能。
        expect(result[:resolved]).to include(subtotal: 500, tax: 0, total: 500, tax_rate: BigDecimal('0'))
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('manual_receipt_input')
      end
    end

    it 'native engineでは明細と入力金額が大きく矛盾するmanual入力候補を勝たせない' do
      result = call_service(
        receipt: {
          subtotal_amount: 9_000,
          tax_amount: 999,
          total_amount: 9_999,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: :manual
      )

      aggregate_failures do
        # 検算: 明細108円の10%内税floorは税9円/税抜99円。入力9,999円とは大きく矛盾するため明細候補を採用する。
        expect(result[:resolved]).to include(subtotal: 99, tax: 9, total: 108, tax_rate: BigDecimal('0.1'))
        expect(result.dig(:amount_engine, :selected_candidate_id)).to start_with('items_as_tax_included/floor')
      end
    end

    it 'native engineでもtax_detail_incompleteをwarningへ移植する' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: nil }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 明細108円の10%内税floorは税9円/税抜99円。税内訳はamount欠落なのでwarningのみ。
        expect(result[:resolved]).to include(subtotal: 99, tax: 9, total: 108)
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
      end
    end

    it 'native engineでも不完全TaxDetailsからreceipt tax_amountを保持しreview対象にする' do
      result = call_service(
        receipt: {
          total_amount: 890,
          tax_amount: 71
        },
        receipt_items: [
          { line_total: 158, tax_rate: nil },
          { line_total: 108, tax_rate: nil },
          { line_total: 198, tax_rate: nil },
          { line_total: 128, tax_rate: nil },
          { line_total: 298, tax_rate: nil }
        ],
        receipt_tax_details: [
          { description: '内消費税等', amount: 44 },
          { description: '内消費税等', amount: 27 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 画像上の合計890円と税額合計71円を保持する。subtotalは 890 - 71 = 819円。
        expect(result[:resolved]).to include(subtotal: 819, tax: 71, total: 890, tax_rate: nil)
        expect(result.dig(:computed, :amount_engine_basis)).to eq('incomplete_tax_details_receipt_tax')
        expect(result.dig(:computed, :item_amount_basis)).to eq(:line_total_as_recorded)
        expect(result[:tax_details]).to be_empty
        expect(result.dig(:amount_engine, :selected_candidate, :evidence)).to include(
          hash_including(source: 'receipt_tax_detail', amount: 44),
          hash_including(source: 'receipt_tax_detail', amount: 27)
        )
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).to be_empty
        expect(result[:review_reasons]).to include('tax_detail_incomplete')
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'native engineのanalysisでは現金お預かりをpurchase total候補選択に使わない' do
      result = call_service(
        receipt: {
          total_amount: 770,
          subtotal_amount: 770,
          tax_amount: 70,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { price: 220, quantity: 1, line_total: 220, tax_rate: BigDecimal('0.1') },
          { price: 132, quantity: 1, line_total: 132, tax_rate: BigDecimal('0.1') },
          { price: 110, quantity: 1, line_total: 110, tax_rate: BigDecimal('0.1') },
          { price: 308, quantity: 1, line_total: 308, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { description: '内消費税等 (10%)', amount: 70, rate: BigDecimal('0.1') },
          { description: '内消費税等', amount: 70 }
        ],
        receipt_payments: [
          { method: '現金', amount: 1_000 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 明細税込合計770円。10%内税は floor(770 * 10 / 110) = 70円、税抜700円。
        # 現金1,000円はお預かり由来の過払い方向なので、770円を税抜として846円にする候補へ寄せない。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('items_as_tax_included/floor/per_tax_rate_group')
        expect(result.dig(:amount_engine, :selected_candidate, :score_breakdown, :payment_delta)).to eq(0)
        expect(result[:resolved]).to include(subtotal: 700, tax: 70, total: 770, tax_rate: BigDecimal('0.1'))
        expect(result[:warning_inconsistencies]).to eq([ :tax_detail_incomplete ])
        expect(result[:review_reasons]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'native engineでもtax_detail_partialをwarningへ移植する' do
      result = call_service(
        receipt: {
          total_amount: 218,
          subtotal_amount: 200,
          tax_amount: 18
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 110, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 8%税8円 + 10%税10円 = 税18円。印字税内訳は8円のみなのでpartial warning。
        expect(result[:resolved]).to include(subtotal: 200, tax: 18, total: 218)
        expect(result[:warning_inconsistencies]).to include(:tax_detail_partial)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
      end
    end

    it 'native engineでもtax_detail_mismatchをblockingへ移植する' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 90, amount: 18 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 明細からは税9円だが、税内訳は税18円なのでblocking mismatch。
        expect(result[:resolved]).to include(subtotal: 99, tax: 9, total: 108)
        expect(result[:blocking_inconsistencies]).to include(:tax_detail_mismatch)
        expect(result[:review_reasons]).to include('tax_detail_mismatch')
      end
    end

    it '印字totalとpaymentが一致しTaxDetailsが内部矛盾する場合はtotalを保持してreview対象にする' do
      result = call_service(
        receipt: {
          total_amount: 999,
          subtotal_amount: 10,
          tax_amount: 22
        },
        receipt_items: [
          { line_total: 120, tax_rate: nil },
          { line_total: 159, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 279, amount: 22 },
          { rate: BigDecimal('0.1'), net_amount: 0, amount: 54 }
        ],
        receipt_payments: [
          { method: 'PayPay', amount: 999 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 977, tax: 22, total: 999)
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('analysis_receipt_input')
        expect(result[:tax_details]).to include(
          hash_including(rate: BigDecimal('0.1'), net_amount: 0, amount: 54)
        )
        expect(result[:blocking_inconsistencies]).to include(:tax_detail_mismatch)
        expect(result[:review_reasons]).to include('tax_detail_mismatch')
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'native engineでもitem_total_mismatchをblockingへ移植する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 300, quantity: 2, quantity_unit_code: 'each', line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: price x quantity は600円だがline_totalは500円。税込/税抜補正候補にも合わないのでitem_total_mismatch。
        expect(result[:resolved]).to include(subtotal: 455, tax: 45, total: 500)
        expect(result[:blocking_inconsistencies]).to include(:item_total_mismatch)
        expect(result[:review_reasons]).to include('item_total_mismatch')
      end
    end

    it 'native engineでもzero_amount_item_incompleteをwarningへ移植する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: nil,
            quantity: nil,
            line_total: 0,
            amount_price_present: false,
            amount_quantity_present: false,
            amount_line_total_present: true
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 0円line_totalは明示されているが、price/quantityが欠けるためwarning。
        expect(result[:resolved]).to include(subtotal: 0, tax: 0, total: 0)
        expect(result[:warning_inconsistencies]).to include(:zero_amount_item_incomplete)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'native engineでも金額情報がない明細をinsufficient_dataへ移植する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: nil,
            quantity: 1,
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 明細にprice/line_totalがなく、receipt totalもtax detailsもないため金額を確定できない。
        expect(result[:resolved]).to include(subtotal: 0, tax: 0, total: 0)
        expect(result[:blocking_inconsistencies]).to include(:insufficient_data)
        expect(result[:review_reasons]).to include('insufficient_data')
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'native engineでもtax_amount_mismatchをblockingへ移植する' do
      result = call_service(
        receipt: {
          total_amount: 108,
          tax_amount: 12
        },
        receipt_items: [
          { line_total: 108, tax_rate: nil }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 税率不明明細108円は税額0円候補。receipt tax_amount 12円とは一致しない。
        expect(result[:resolved]).to include(subtotal: 108, tax: 0, total: 108)
        expect(result[:blocking_inconsistencies]).to include(:tax_amount_mismatch)
        expect(result[:review_reasons]).to include('tax_amount_mismatch')
      end
    end

    it 'native engineでもprice_tax_inclusion_uncertainをreview reasonへ移植する' do
      result = call_service(
        receipt: {
          tax_rate: nil
        },
        receipt_items: [
          { line_total: 130, tax_rate: BigDecimal('0.08') },
          { line_total: 140, tax_rate: BigDecimal('0.08') },
          { line_total: 300, tax_rate: BigDecimal('0.1') },
          { line_total: 490, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 270, amount: 21 },
          { rate: BigDecimal('0.1'), net_amount: 300, amount: 30 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 明細合計は1,110円。印字税内訳は8%税21円 + 10%税30円のみで、
        # 490円10%税込行や50円非課税行が税内訳に含まれず、税抜/税込混在の可能性が残る。
        expect(result[:resolved]).to include(subtotal: 1_019, tax: 91, total: 1_110)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain')
      end
    end

    it 'native engineでも外税のambiguous warningをreviewなしで投影する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_101
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 外税TaxDetailsは1,000円 + 10%税100円 = 1,100円。
        # OCR totalの1,101円とは1円差だが、旧互換では税込/税抜判定のwarning-onlyとして扱う。
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_mismatch_codes]).to include('PRICE_TAX_INCLUSION_UNCERTAIN')
        expect(result[:warning_reasons]).to include('price_tax_inclusion_uncertain')
        expect(result[:review_reasons]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'native engineでもお預かり誤認totalより外税税額一致候補を優先する' do
      result = call_service(
        receipt: {
          subtotal_amount: 601,
          tax_amount: 48,
          total_amount: 601,
          tax_rate: BigDecimal('0.08')
        },
        receipt_items: [
          { price: 158, quantity: 1, line_total: 158, tax_rate: BigDecimal('0.08') },
          { price: 228, quantity: 1, line_total: 228, tax_rate: BigDecimal('0.08') },
          { price: 215, quantity: 1, line_total: 215, tax_rate: BigDecimal('0.08') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 601, amount: 48, description: '外税額' },
          { amount: 48, description: '内消費税等' }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: OCR total=601はお預かり/小計系の誤認。外税TaxDetailsは税抜601円 + 税48円 = 649円。
        # 648円のper_item候補はOCR totalに1円近いが、印字税額48円と一致しないため採用しない。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('external_tax_from_receipt/floor')
        expect(result.dig(:amount_engine, :selected_candidate, :score_breakdown, :external_tax_exact_tax_bonus)).to eq(-100)
        expect(result[:resolved]).to include(subtotal: 601, tax: 48, total: 649, tax_rate: BigDecimal('0.08'))
        expect(result[:warning_inconsistencies]).to eq([ :ocr_total_mismatch, :price_tax_inclusion_uncertain ])
        expect(result[:review_reasons]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'native engineでも同一税率のP3 mixed warningをreviewなしにする' do
      result = call_service(
        receipt: {
          subtotal_amount: 200,
          tax_amount: 20,
          total_amount: 220
        },
        receipt_items: [
          { line_total: 110, tax_rate: BigDecimal('0.1') },
          { line_total: 100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: TaxDetailsは税抜200円 + 10%税20円 = 220円。
        # 同一税率内の税込/税抜推定は残るが、TaxDetailsが全額説明できるためwarning-onlyにする。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('printed_tax_details_net/floor')
        expect(result[:resolved]).to include(subtotal: 200, tax: 20, total: 220)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:review_reasons]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'native engineでも印字税詳細がreceipt totalを説明する場合は税率不明itemを非課税加算しない' do
      result = call_service(
        receipt: {
          total_amount: 890,
          tax_amount: 71
        },
        receipt_items: [
          { line_total: 158 },
          { line_total: 108 },
          { line_total: 19 },
          { line_total: 12 },
          { line_total: 8 }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 548, amount: 44, description: '8%対象' },
          { rate: BigDecimal('0.1'), net_amount: 271, amount: 27, description: '10%対象' }
        ],
        receipt_payments: [
          { method: 'クレジット支払', amount: 890 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('printed_tax_details_net/floor')
        expect(result[:resolved]).to include(subtotal: 819, tax: 71, total: 890, tax_rate: nil)
        expect(result.dig(:computed, :adjusted_item_total)).to eq(305)
        expect(result[:blocking_inconsistencies]).to be_empty
        expect(result[:warning_inconsistencies]).to be_empty
      end
    end

    it 'native engineでも税率対象額をgross basis候補として採用する' do
      result = call_service(
        receipt: {
          total_amount: 1_100
        },
        receipt_items: [
          { line_total: 1_100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_100, amount: 100, description: '10%対象' }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 1,100円は税込10%対象額。floor(1,100 * 10 / 110) = 税100円なのでgross basis。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('printed_tax_details_gross/floor')
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100)
        expect(result[:computed]).to include(tax_detail_amount_basis: :gross, receipt_tax_basis: :total_includes_tax)
        expect(result[:blocking_inconsistencies]).to be_empty
      end
    end

    it 'native engineでもreceipt三点整合とTaxDetails net合計が一致する場合はnet basisを採用する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_598,
          tax_amount: 134,
          total_amount: 1_732
        },
        receipt_items: [
          { line_total: 198, tax_rate: BigDecimal('0.08') },
          { line_total: 248, tax_rate: BigDecimal('0.08') },
          { line_total: 158, tax_rate: BigDecimal('0.08') },
          { line_total: 398, tax_rate: BigDecimal('0.1') },
          { line_total: 298, tax_rate: BigDecimal('0.1') },
          { line_total: 298, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 604, amount: 44, description: '8%対象額' },
          { rate: BigDecimal('0.1'), net_amount: 994, amount: 90, description: '10%対象額' }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: TaxDetails net合計 604 + 994 = 1,598、税額 44 + 90 = 134。
        # receiptも subtotal 1,598 + tax 134 = total 1,732 なので、対象額ラベルでもnet basisを正にしてwarningは出さない。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('printed_tax_details_net/floor')
        expect(result[:resolved]).to include(subtotal: 1_598, tax: 134, total: 1_732, tax_rate: nil)
        expect(result[:computed]).to include(tax_detail_amount_basis: :net, receipt_tax_basis: :tax_added_to_subtotal)
        expect(result[:warning_inconsistencies]).to eq([])
        expect(result[:review_reasons]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'native engineでも税抜対象額をnet basisの外税候補として採用する' do
      result = call_service(
        receipt: {
          total_amount: 1_100
        },
        receipt_items: [
          { line_total: 1_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100, description: '外税10%' }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 税抜1,000円 + 外税10% 100円 = 1,100円。明細line_totalはnet basisとして扱う。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('external_tax_from_receipt/floor')
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100)
        expect(result[:computed]).to include(tax_detail_amount_basis: :net, receipt_tax_basis: :tax_added_to_subtotal)
        expect(result[:blocking_inconsistencies]).to be_empty
      end
    end

    it 'native engineでもTaxDetailsに含まれない明示0%明細を残す' do
      result = call_service(
        receipt: {
          total_amount: 1_140
        },
        receipt_items: [
          { line_total: 540, tax_rate: BigDecimal('0.08') },
          { line_total: 550, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: BigDecimal('0') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 500, amount: 40 },
          { rate: BigDecimal('0.1'), net_amount: 500, amount: 50 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: TaxDetailsは taxable gross 540 + 550 = 1,090円を説明する。
        # 明示0%の50円はTaxDetails外の非課税明細として残し、購入合計は1,090 + 50 = 1,140円。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('printed_tax_details_net/floor')
        expect(result[:resolved]).to include(subtotal: 1_050, tax: 90, total: 1_140, tax_rate: nil)
        expect(result[:tax_details]).to contain_exactly(
          include(rate: BigDecimal('0.08'), net_amount: 500, amount: 40),
          include(rate: BigDecimal('0.1'), net_amount: 500, amount: 50)
        )
        expect(result[:blocking_inconsistencies]).to be_empty
      end
    end

    it 'native engineでも中間TaxDetailsを二重計上せず混在候補を採用する' do
      result = call_service(
        receipt: {
          total_amount: 1_161,
          subtotal_amount: 10,
          tax_amount: 125
        },
        receipt_items: [
          { price: 130, quantity: 1, quantity_unit_code: 'each', line_total: 130, tax_rate: BigDecimal('0.08') },
          { price: 140, quantity: 1, quantity_unit_code: 'each', line_total: 140, tax_rate: BigDecimal('0.08') },
          { price: 300, quantity: 1, quantity_unit_code: 'each', line_total: 300, tax_rate: BigDecimal('0.1') },
          { price: 490, quantity: 1, quantity_unit_code: 'each', line_total: 490, tax_rate: BigDecimal('0.1') },
          { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
          { rate: BigDecimal('0.1'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
          { rate: BigDecimal('0.1'), net_amount: 820, amount: 74, description: '10%対象' }
        ],
        receipt_adjustments: [
          { kind: 'receipt_discount', label: 'キャッシュレス還元額', sign: 'discount', amount: 22 }
        ],
        receipt_payments: [
          { method: 'nanaco支払', amount: 1_139 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 8%は130税抜->140税込 + 140税抜->151税込 = 291/税21。
        # 10%は300税抜->330税込 + 490税込 = 820/税74。非課税50。購入合計1,161、支払調整-22で実支払1,139。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
        expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
        expect(result.dig(:computed, :final_payment_total)).to eq(1_139)
        expect(result[:tax_details]).to contain_exactly(
          include(rate: BigDecimal('0.08'), net_amount: 270, amount: 21),
          include(rate: BigDecimal('0.1'), net_amount: 746, amount: 74)
        )
        expect(result.dig(:amount_engine, :candidates).map { |candidate| candidate[:candidate_id] }).not_to include('printed_tax_details_raw_sum/floor')
        expect(result[:blocking_inconsistencies]).to be_empty
        expect(result[:warning_inconsistencies]).to be_empty
      end
    end

    it 'AI由来の一部item税率がずれても印字税詳細に合う混在候補を採用する' do
      result = call_service(
        receipt: {
          total_amount: 1_161,
          subtotal_amount: 1_066,
          tax_amount: 95
        },
        receipt_items: [
          { price: 130, quantity: 1, quantity_unit_code: 'each', line_total: 130, tax_rate: BigDecimal('0.08') },
          { price: 140, quantity: 1, quantity_unit_code: 'each', line_total: 140, tax_rate: BigDecimal('0.1') },
          { price: 300, quantity: 1, quantity_unit_code: 'each', line_total: 300, tax_rate: BigDecimal('0.1') },
          { price: 490, quantity: 1, quantity_unit_code: 'each', line_total: 490, tax_rate: BigDecimal('0.1') },
          { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 270, amount: 21, description: '8%対象' },
          { rate: BigDecimal('0.1'), net_amount: 300, amount: 30, description: '小計（税抜10%）' },
          { rate: BigDecimal('0.1'), net_amount: 820, amount: 74, description: '10%対象' }
        ],
        receipt_adjustments: [
          { kind: 'receipt_discount', label: 'キャッシュレス還元額', sign: 'discount', amount: 22 }
        ],
        receipt_payments: [
          { method: 'nanaco支払', amount: 1_139 }
        ],
        context: :analysis
      )

      computed_items = Array(result.dig(:computed, :items))

      aggregate_failures do
        # 検算: 2行目はAIでは10%にdriftしているが、印字税詳細8%対象291へ入れると完全整合する。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('mixed_by_tax_rate_group/floor')
        expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
        expect(result.dig(:computed, :final_payment_total)).to eq(1_139)
        expect(computed_items.map { |item| item[:line_total] || item['line_total'] }).to eq([ 140, 151, 330, 490, 50 ])
        expect(computed_items.map { |item| item[:tax_rate] || item['tax_rate'] }).to eq([
          BigDecimal('0.08'),
          BigDecimal('0.08'),
          BigDecimal('0.1'),
          BigDecimal('0.1'),
          BigDecimal('0')
        ])
        expect(result[:tax_details]).to contain_exactly(
          include(rate: BigDecimal('0.08'), net_amount: 270, amount: 21),
          include(rate: BigDecimal('0.1'), net_amount: 746, amount: 74)
        )
        expect(result[:blocking_inconsistencies]).to be_empty
        expect(result[:warning_inconsistencies]).to be_empty
      end
    end

    it 'native engineでもanalysisの明細なしreceipt入力をsubtotalとtaxから補完する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100
        },
        receipt_items: [],
        receipt_tax_details: [],
        context: :analysis
      )

      aggregate_failures do
        # 検算: subtotal 1,000 + tax 100 = total 1,100。税率は100 / 1,000 = 10%。
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq('analysis_receipt_input')
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: BigDecimal('0.1'))
      end
    end

    it 'native engineでもanalysisの明細なしreceipt入力をtotalとsubtotalから補完する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          total_amount: 1_100
        },
        receipt_items: [],
        receipt_tax_details: [],
        context: :analysis
      )

      aggregate_failures do
        # 検算: total 1,100 - subtotal 1,000 = tax 100。tax_amountは未入力なのでtax_rateはnilのまま。
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: nil)
      end
    end

    it 'native engineでもanalysisの明細なしreceipt入力をtotalとtaxから補完する' do
      result = call_service(
        receipt: {
          tax_amount: 100,
          total_amount: 1_100
        },
        receipt_items: [],
        receipt_tax_details: [],
        context: :analysis
      )

      aggregate_failures do
        # 検算: total 1,100 - tax 100 = subtotal 1,000。税率は100 / 1,000 = 10%。
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100, tax_rate: BigDecimal('0.1'))
      end
    end

    it 'native engineでもtax 0とtax_rate nil/0を区別する' do
      tax_nil_result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 0
        },
        receipt_items: [],
        receipt_tax_details: [],
        context: :analysis
      )
      tax_rate_zero_result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 0,
          tax_rate: 0
        },
        receipt_items: [],
        receipt_tax_details: [],
        context: :analysis
      )
      total_only_result = call_service(
        receipt: {
          total_amount: 1_000
        },
        receipt_items: [],
        receipt_tax_details: [],
        context: :analysis
      )

      aggregate_failures do
        # 検算: tax_amount 0が明示されていればtotalは1,000、税率は0%。tax_rate 0明示も0%。
        # totalのみ入力では税額根拠がないためtax_rateはnilのまま。
        expect(tax_nil_result[:resolved]).to include(subtotal: 1_000, tax: 0, total: 1_000, tax_rate: BigDecimal('0'))
        expect(tax_rate_zero_result[:resolved]).to include(subtotal: 1_000, tax: 0, total: 1_000, tax_rate: BigDecimal('0'))
        expect(total_only_result[:resolved]).to include(subtotal: 0, tax: 0, total: 1_000, tax_rate: nil)
      end
    end

    it 'native engineのmanual/edit_saveでもcalculation_profile出力を旧互換のまま保持する' do
      manual_result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 999,
            quantity: 1,
            quantity_unit_code: 'each',
            discount_rate: BigDecimal('0.105'),
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )
      edit_result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100
        },
        receipt_items: [
          { price: 1_000, quantity: 1, quantity_unit_code: 'each', line_total: 1_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100, description: '外税' }
        ],
        context: :edit_save
      )

      aggregate_failures do
        # 検算: manual/edit_saveではAmount Engine候補を使っても、旧UI/保存互換のためprofile推定欄は出さない。
        expect(manual_result[:calculation_profile]).to be_nil
        expect(manual_result[:calculation_profile_score]).to be_nil
        expect(manual_result[:calculation_profile_candidates]).to eq([])
        expect(edit_result[:calculation_profile]).to be_nil
        expect(edit_result[:calculation_profile_score]).to be_nil
        expect(edit_result[:calculation_profile_candidates]).to eq([])
        expect(edit_result[:computed]).to include(item_amount_basis: :line_total_as_recorded)
      end
    end

    it 'snapshot保存に必要なcontextとrounding_modeを返す' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: :manual,
        tax_rounding_mode: :ceil,
        discount_rounding_mode: :floor
      )

      aggregate_failures do
        expect(result[:context]).to eq(:manual)
        expect(result[:rounding_mode]).to eq(tax: :ceil, discount: :floor)
        expect(result[:computed]).to include(:subtotal, :tax, :total)
        expect(result[:resolved]).to include(:subtotal, :tax, :total)
        expect(result).to have_key(:mismatch_codes)
        expect(result).to have_key(:blocking_mismatch_codes)
        expect(result).to have_key(:warning_mismatch_codes)
      end
    end

    it '特殊加減算をadjusted_item_totalへ反映して明細合計不一致を解消する' do
      result = call_service(
        receipt: { total_amount: 1_640 },
        receipt_items: [
          { line_total: 1_080 }
        ],
        receipt_adjustments: [
          { kind: 'bag_fee', amount: 10, sign: 'surcharge' },
          { kind: 'delivery_fee', amount: 550, sign: 'surcharge' }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :adjustment_surcharge_total)).to eq(560)
        expect(result.dig(:computed, :adjustment_discount_total)).to eq(0)
        expect(result.dig(:computed, :adjusted_item_total)).to eq(1_640)
        expect(result[:resolved][:total]).to eq(1_640)
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it '値引きadjustmentをadjusted_item_totalへ反映する' do
      result = call_service(
        receipt: { total_amount: 1_000 },
        receipt_items: [
          { line_total: 1_980 }
        ],
        receipt_adjustments: [
          { kind: 'return_refund', amount: 980, sign: 'discount' }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :adjustment_discount_total)).to eq(980)
        expect(result.dig(:computed, :adjusted_item_total)).to eq(1_000)
        expect(result[:resolved][:total]).to eq(1_000)
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it 'manual sourceのother adjustmentは確認対象にしない' do
      result = call_service(
        receipt: { total_amount: 1_100 },
        receipt_items: [
          { line_total: 1_000 }
        ],
        receipt_adjustments: [
          { kind: 'other', amount: 100, sign: 'surcharge', source: 'manual' }
        ]
      )

      aggregate_failures do
        expect(result[:blocking_inconsistencies]).not_to include(:adjustment_uncertain)
        expect(result[:needs_review]).to eq(false)
      end
    end

    it 'ai/ocr sourceのother adjustmentは確認対象にする' do
      result = call_service(
        receipt: { total_amount: 1_000 },
        receipt_items: [
          { line_total: 1_000 }
        ],
        receipt_adjustments: [
          { kind: 'other', amount: 100, sign: 'discount', source: 'ai' },
          { kind: 'other', amount: 50, sign: 'surcharge', source: 'ocr' }
        ]
      )

      aggregate_failures do
        expect(result[:blocking_inconsistencies]).to include(:adjustment_uncertain)
        expect(result[:needs_review]).to eq(true)
      end
    end

    it 'needs_review adjustmentは確認対象にする' do
      result = call_service(
        receipt: { total_amount: 1_000 },
        receipt_items: [
          { line_total: 1_000 }
        ],
        receipt_adjustments: [
          { kind: 'delivery_fee', amount: 100, sign: 'surcharge', source: 'manual', needs_review: true }
        ]
      )

      aggregate_failures do
        expect(result[:blocking_inconsistencies]).to include(:adjustment_uncertain)
        expect(result[:needs_review]).to eq(true)
      end
    end

    it 'サービス料と深夜料金を外税の税内訳と合計整合に反映する' do
      result = call_service(
        receipt: {
          subtotal_amount: 5_832,
          tax_amount: 583,
          total_amount: 6_415
        },
        receipt_items: [
          { line_total: 4_860, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 5_832, amount: 583 }
        ],
        receipt_adjustments: [
          { kind: 'service_charge', sign: 'surcharge', amount: 486, tax_rate: BigDecimal('0.1') },
          { kind: 'late_night_charge', sign: 'surcharge', amount: 486, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :receipt_tax_basis)).to eq(:tax_added_to_subtotal)
        expect(result.dig(:computed, :adjusted_item_total)).to eq(5_832)
        expect(result[:resolved]).to include(subtotal: 5_832, tax: 583, total: 6_415)
        expect(result[:tax_details]).to include(include(rate: BigDecimal('0.1'), net_amount: 5_832, amount: 583))
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch, :tax_detail_mismatch, :total_mismatch)
      end
    end

    it '配送料と袋代を外税の税内訳と合計整合に反映する' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_640,
          tax_amount: 164,
          total_amount: 1_804
        },
        receipt_items: [
          { line_total: 1_080, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_640, amount: 164 }
        ],
        receipt_adjustments: [
          { kind: 'bag_fee', sign: 'surcharge', amount: 10, tax_rate: BigDecimal('0.1') },
          { kind: 'delivery_fee', sign: 'surcharge', amount: 550, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :adjusted_item_total)).to eq(1_640)
        expect(result[:resolved]).to include(subtotal: 1_640, tax: 164, total: 1_804)
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch, :tax_detail_mismatch, :total_mismatch)
      end
    end

    it '返品行を負値itemなしで外税の税内訳と合計整合に反映する' do
      result = call_service(
        receipt: {
          subtotal_amount: 530,
          tax_amount: 53,
          total_amount: 583
        },
        receipt_items: [
          { line_total: 1_510, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 530, amount: 53 }
        ],
        receipt_adjustments: [
          { kind: 'return_refund', sign: 'discount', amount: 980, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :adjusted_item_total)).to eq(530)
        expect(result[:resolved]).to include(subtotal: 530, tax: 53, total: 583)
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch, :tax_detail_mismatch, :total_mismatch)
      end
    end

    it '税詳細対象額合計が調整後明細合計と一致し税額も内税として整合する場合はgross basisで税を足し直さない' do
      result = call_service(
        receipt: {
          subtotal_amount: 2_204,
          total_amount: 5_000
        },
        receipt_items: [
          { line_total: 4_320, tax_rate: BigDecimal('0.08') },
          { line_total: 44, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 2_160, amount: 160 },
          { rate: BigDecimal('0.1'), net_amount: 44, amount: 4 }
        ],
        receipt_adjustments: [
          { kind: 'receipt_discount', sign: 'discount', amount: 2_160, tax_rate: BigDecimal('0.08'), source: 'ai' }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :adjusted_item_total)).to eq(2_204)
        expect(result.dig(:computed, :tax_detail_amount_basis)).to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 2_040, tax: 164, total: 2_204)
        expect(result[:tax_details]).to contain_exactly(
          include(rate: BigDecimal('0.08'), net_amount: 2_000, amount: 160),
          include(rate: BigDecimal('0.1'), net_amount: 40, amount: 4)
        )
        expect(result[:warning_inconsistencies]).to include(:ocr_total_mismatch)
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch, :tax_detail_mismatch, :total_mismatch)
      end
    end

    it '外税単一税率で対象額と税額の合計がOCR totalに一致する場合はgross basisにしない' do
      result = call_service(
        receipt: {
          total_amount: 1_100
        },
        receipt_items: [
          { line_total: 1_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100)
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch, :tax_detail_mismatch, :total_mismatch)
      end
    end

    it '外税複数税率で対象額と税額の合計がOCR totalに一致する場合はgross basisにしない' do
      result = call_service(
        receipt: {
          total_amount: 3_280
        },
        receipt_items: [
          { line_total: 1_000, tax_rate: BigDecimal('0.08') },
          { line_total: 2_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 1_000, amount: 80 },
          { rate: BigDecimal('0.1'), net_amount: 2_000, amount: 200 }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 3_000, tax: 280, total: 3_280)
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch, :tax_detail_mismatch, :total_mismatch)
      end
    end

    it '加算adjustment込み外税で対象額と税額の合計がOCR totalに一致する場合はgross basisにしない' do
      result = call_service(
        receipt: {
          total_amount: 2_750
        },
        receipt_items: [
          { line_total: 2_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 2_500, amount: 250 }
        ],
        receipt_adjustments: [
          { kind: 'service_charge', sign: 'surcharge', amount: 500, tax_rate: BigDecimal('0.1'), source: 'ai' }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :adjusted_item_total)).to eq(2_500)
        expect(result.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 2_500, tax: 250, total: 2_750)
      end
    end

    it '減算adjustment込み外税で対象額と税額の合計がOCR totalに一致する場合はgross basisにしない' do
      result = call_service(
        receipt: {
          total_amount: 2_750
        },
        receipt_items: [
          { line_total: 3_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 2_500, amount: 250 }
        ],
        receipt_adjustments: [
          { kind: 'receipt_discount', sign: 'discount', amount: 500, tax_rate: BigDecimal('0.1'), source: 'ai' }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :adjusted_item_total)).to eq(2_500)
        expect(result.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 2_500, tax: 250, total: 2_750)
      end
    end

    it '税詳細対象額が調整後明細合計と一致してもOCR totalがない場合は安易にgross basisにしない' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 1_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100)
      end
    end

    it '税詳細対象額と税額の合計がOCR totalに一致する場合はnet basisを優先する' do
      result = call_service(
        receipt: {
          total_amount: 1_100
        },
        receipt_items: [
          { line_total: 1_000, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :tax_detail_amount_basis)).not_to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100)
      end
    end

    it '税詳細対象額がOCR totalと一致し税額も内税として整合する場合はgross basis候補にする' do
      result = call_service(
        receipt: {
          total_amount: 1_100
        },
        receipt_items: [
          { line_total: 1_100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_100, amount: 100 }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :tax_detail_amount_basis)).to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 1_000, tax: 100, total: 1_100)
        expect(result[:blocking_inconsistencies]).not_to include(:total_mismatch, :tax_detail_mismatch)
      end
    end

    it '預かり金額をOCR totalとして誤認してもsubtotalと税詳細対象額が調整後明細合計に一致する場合はgross basisで補正する' do
      result = call_service(
        receipt: {
          total_amount: 5_000,
          subtotal_amount: 2_204
        },
        receipt_items: [
          { line_total: 4_320, tax_rate: BigDecimal('0.08') },
          { line_total: 44, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 2_160, amount: 160 },
          { rate: BigDecimal('0.1'), net_amount: 44, amount: 4 }
        ],
        receipt_adjustments: [
          { kind: 'receipt_discount', sign: 'discount', amount: 2_160, tax_rate: BigDecimal('0.08'), source: 'ai' }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :tax_detail_amount_basis)).to eq(:gross)
        expect(result[:resolved]).to include(subtotal: 2_040, tax: 164, total: 2_204)
        expect(result[:warning_inconsistencies]).to include(:ocr_total_mismatch)
        expect(result[:blocking_inconsistencies]).not_to include(:total_mismatch)
      end
    end

    it 'point_usageは税内訳を変えず支払調整として保持する' do
      result = call_service(
        receipt: { total_amount: 1_100 },
        receipt_items: [
          { line_total: 1_100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_adjustments: [
          { kind: 'point_usage', sign: 'discount', amount: 500, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result.dig(:computed, :payment_adjustment_total)).to eq(-500)
        expect(result.dig(:computed, :adjusted_item_total)).to eq(1_100)
        expect(result[:tax_details]).to include(include(rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100))
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it '単一10%対象が合計全体に一致するレシートは深夜料金込みで税額126円へ整合する' do
      result = call_service(
        receipt: {
          total_amount: 1_391,
          tax_amount: 126,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 900, tax_rate: BigDecimal('0.1') },
          { line_total: 400, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), amount: 126, description: '内消費税' }
        ],
        receipt_adjustments: [
          { kind: 'late_night_charge', sign: 'surcharge', amount: 91, tax_rate: BigDecimal('0.1') }
        ]
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 1_265, tax: 126, total: 1_391, tax_rate: BigDecimal('0.1'))
        expect(result[:tax_details]).to eq([
          {
            description: '10%対象',
            rate: BigDecimal('0.1'),
            net_amount: 1_265,
            amount: 126
          }
        ])
        expect(result[:blocking_inconsistencies]).not_to include(:item_total_mismatch, :tax_detail_mismatch, :total_mismatch)
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
      end
    end

    it 'tax_rateなしadjustmentはwarningに留める' do
      result = call_service(
        receipt: { total_amount: 1_300 },
        receipt_items: [
          { line_total: 1_000 }
        ],
        receipt_adjustments: [
          { kind: 'handling_fee', sign: 'surcharge', amount: 300 }
        ]
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:adjustment_tax_rate_missing)
        expect(result[:blocking_inconsistencies]).not_to include(:adjustment_tax_rate_missing)
        expect(result.dig(:computed, :adjustment_tax_rate_missing_total)).to eq(300)
      end
    end

    it '単一10%明細では税率未指定couponへ税率を継承する' do
      result = call_service(
        receipt: { total_amount: 90 },
        receipt_items: [
          { line_total: 100, tax_rate: BigDecimal('0.10') }
        ],
        receipt_adjustments: [
          { kind: 'coupon', sign: 'discount', amount: 10, source: 'manual' }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 82, tax: 8, total: 90)
        expect(result[:warning_inconsistencies]).not_to include(:adjustment_tax_rate_missing)
        expect(result[:review_reasons]).not_to include('purchase_adjustment_tax_allocation_uncertain')
        expect(result.dig(:amount_engine, :selected_candidate, :evidence)).to include(
          include(
            source: 'receipt_adjustment',
            tax_rate: BigDecimal('0.10'),
            tax_rate_source: 'inherited_single_rate'
          )
        )
      end
    end

    it '同点なら国内内税を税率グループ単位で丸める' do
      result = call_service(
        receipt: { total_amount: 12 },
        receipt_items: [
          { line_total: 6, tax_rate: BigDecimal('0.10') },
          { line_total: 6, tax_rate: BigDecimal('0.10') }
        ]
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 11, tax: 1, total: 12)
        expect(result.dig(:amount_engine, :selected_candidate_id)).to eq(
          'items_as_tax_included/floor/per_tax_rate_group'
        )
      end
    end

    it '明示0%のcouponを10%へ継承しない' do
      result = call_service(
        receipt: { total_amount: 90 },
        receipt_items: [
          { line_total: 100, tax_rate: BigDecimal('0.10') }
        ],
        receipt_adjustments: [
          { kind: 'coupon', sign: 'discount', amount: 10, tax_rate: BigDecimal('0'), source: 'manual' }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 81, tax: 9, total: 90)
        expect(result[:warning_inconsistencies]).not_to include(:adjustment_tax_rate_missing)
      end
    end

    it 'purchase totalを下回る過大なcouponを自動完了候補にしない' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0') }
        ],
        receipt_adjustments: [
          { kind: 'coupon', label: 'クーポン', amount: 200, sign: 'discount', tax_rate: BigDecimal('0'), source: 'manual' }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 0, tax: 0, total: 0)
        expect(result[:review_reasons]).to include('invalid_amount_relation')
        expect(result[:safe_to_auto_complete]).to be(false)
      end
    end

    it 'final payment totalを負にするpoint usageを自動完了候補にしない' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0') }
        ],
        receipt_adjustments: [
          { kind: 'point_usage', label: 'ポイント利用', amount: 200, sign: 'discount', source: 'manual' }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 100, tax: 0, total: 100)
        expect(result.dig(:computed, :final_payment_total)).to eq(-100)
        expect(result[:review_reasons]).to include('invalid_amount_relation')
        expect(result[:safe_to_auto_complete]).to be(false)
      end
    end

    it '支払調整があるのに支払行がなければ照合済み扱いにしない' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 100, quantity: 1, quantity_unit_code: 'each', line_total: 100, tax_rate: BigDecimal('0') }
        ],
        receipt_adjustments: [
          { kind: 'point_usage', label: 'ポイント利用', amount: 10, sign: 'discount', source: 'manual' }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result.dig(:computed, :final_payment_total)).to eq(90)
        expect(result[:review_reasons]).to include('payment_amount_mismatch')
        expect(result[:safe_to_auto_complete]).to be(false)
      end
    end

    it 'return refund後もpurchase totalが非負なら既存のreview draftを維持する' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 1_000, quantity: 1, quantity_unit_code: 'each', line_total: 1_000, tax_rate: BigDecimal('0') }
        ],
        receipt_adjustments: [
          { kind: 'return_refund', label: '返品', amount: 200, sign: 'discount', tax_rate: BigDecimal('0'), source: 'ocr', needs_review: true }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(800)
        expect(result[:review_reasons]).to include('adjustment_uncertain')
        expect(result[:review_reasons]).not_to include('invalid_amount_relation')
      end
    end

    it 'allowlist外のitem_discountはother相当の不確実な調整行として扱う' do
      result = call_service(
        receipt: { total_amount: 900 },
        receipt_items: [
          { original_line_total: 1_000, line_total: 900, discount_amount: 100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_adjustments: [
          { kind: 'item_discount', sign: 'discount', amount: 100, tax_rate: BigDecimal('0.1') }
        ]
      )

      expect(result[:blocking_inconsistencies]).to include(:adjustment_uncertain)
    end

    it 'corrects total_amount from subtotal_amount plus tax_amount' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100
        },
        receipt_items: []
      )

      expect(result[:resolved][:total]).to eq(1_100)
    end

    it 'corrects tax_amount from total_amount minus subtotal_amount' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000
        },
        receipt_items: []
      )

      expect(result[:resolved][:tax]).to eq(100)
    end

    it 'infers tax_rate from tax_amount divided by subtotal_amount' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100
        },
        receipt_items: []
      )

      expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
    end

    it 'sets resolved tax_rate to nil when multiple item tax rates exist' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 110, tax_rate: BigDecimal('0.1') }
        ]
      )

      expect(result[:resolved][:tax_rate]).to be_nil
    end

    it 'prefers item calculation in manual context when items are present' do
      result = call_service(
        receipt: {
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
      end
    end

    it 'preserves user-entered amounts in manual context when no items exist' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end

    it 'keeps manual empty amount input nil when no valid items exist' do
      result = call_service(
        receipt: {},
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to be_nil
        expect(result[:resolved][:subtotal]).to be_nil
        expect(result[:resolved][:tax]).to be_nil
        expect(result[:resolved][:tax_rate]).to be_nil
      end
    end

    it 'preserves explicit zero amount input in manual context' do
      result = call_service(
        receipt: {
          total_amount: 0,
          subtotal_amount: 0,
          tax_amount: 0
        },
        receipt_items: [],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(0)
        expect(result[:resolved][:subtotal]).to eq(0)
        expect(result[:resolved][:tax]).to eq(0)
      end
    end

    it 'accepts symbol context values' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :manual
      )

      expect(result[:resolved][:total]).to eq(1_100)
    end

    it 'normalizes string context values to symbols' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: 'manual'
      )

      expect(result[:resolved][:total]).to eq(1_100)
    end

    it 'falls back nil context to analysis' do
      result = call_service(
        receipt: {
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: nil
      )

      expect(result[:resolved][:total]).to eq(108)
    end

    it 'preserves user-entered amounts in edit_save context when no items exist' do
      result = call_service(
        receipt: {
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end

    [ :manual, :edit_save ].each do |context|
      it "#{context} context keeps tax-normalized saved items as tax-included amounts" do
        result = call_service(
          receipt: {
            total_amount: 1_161,
            subtotal_amount: 1_066,
            tax_amount: 95
          },
          receipt_items: [
            { price: 140, quantity: 1, quantity_unit_code: 'each', original_line_total: 130, line_total: 140, tax_rate: BigDecimal('0.08') },
            { price: 151, quantity: 1, quantity_unit_code: 'each', original_line_total: 140, line_total: 151, tax_rate: BigDecimal('0.08') },
            { price: 330, quantity: 1, quantity_unit_code: 'each', original_line_total: 300, line_total: 330, tax_rate: BigDecimal('0.10') },
            { price: 490, quantity: 1, quantity_unit_code: 'each', original_line_total: 490, line_total: 490, tax_rate: BigDecimal('0.10') },
            { price: 50, quantity: 1, quantity_unit_code: 'each', original_line_total: 50, line_total: 50, tax_rate: BigDecimal('0') }
          ],
          receipt_adjustments: [
            { kind: 'receipt_discount', label: 'キャッシュレス還元額', sign: 'discount', amount: 22 }
          ],
          receipt_payments: [
            { method: 'nanaco支払', amount: 1_139 }
          ],
          context: context
        )

        selected = result.dig(:amount_engine, :selected_candidate)

        aggregate_failures do
          # 検算: 税込明細 140 + 151 + 330 + 490 + 50 = 1,161。支払調整 -22 で実支払額 1,139。
          # original_line_total はOCR元値として残っていても、manual/edit_saveの計算では現在の税込price/line_totalを正とする。
          expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161, tax_rate: nil)
          expect(result.dig(:computed, :payment_adjustment_total)).to eq(-22)
          expect(result.dig(:computed, :final_payment_total)).to eq(1_139)
          expect(Array(result.dig(:computed, :items)).map { |item| item[:price] || item['price'] }).to eq([ 140, 151, 330, 490, 50 ])
          expect(Array(result.dig(:computed, :items)).map { |item| item[:line_total] || item['line_total'] }).to eq([ 140, 151, 330, 490, 50 ])
          expect(selected[:purchase_total]).to eq(1_161)
          expect(selected[:final_payment_total]).to eq(1_139)
        end
      end
    end

    it 'treats unknown context as analysis' do
      result = call_service(
        receipt: {
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        context: :unexpected
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(108)
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
      end
    end

    it 'uses multiple tax_details in analysis context and keeps resolved tax_rate nil' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 1_090 }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 500, amount: 40 },
          { rate: BigDecimal('0.1'), net_amount: 500, amount: 50 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(90)
        expect(result[:resolved][:total]).to eq(1_090)
        expect(result[:resolved][:tax_rate]).to be_nil
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'uses tax_details in analysis context when item tax_rate is missing' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 1_100 }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not need review for ordinary tax-included tax_details matching item gross total' do
      result = call_service(
        receipt: {
          total_amount: 500,
          subtotal_amount: 455,
          tax_amount: 45,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 455,
          tax: 45,
          total: 500,
          tax_rate: BigDecimal('0.1')
        )
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not need review for recovered mixed-rate tax-included details and matching cash payment' do
      result = call_service(
        receipt: {
          total_amount: 844,
          subtotal_amount: nil,
          tax_amount: 70,
          tax_rate: nil
        },
        receipt_items: [
          { raw_text: '商品A', price: 151, quantity: 1, line_total: 151, tax_rate: BigDecimal('0.08') },
          { raw_text: '商品B', price: 178, quantity: 1, line_total: 178, tax_rate: BigDecimal('0.08') },
          { raw_text: '商品C', price: 155, quantity: 1, line_total: 155, tax_rate: BigDecimal('0.1') },
          { raw_text: '商品D', price: 360, quantity: 1, line_total: 360, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { description: '8%対象', rate: BigDecimal('0.08'), net_amount: 305, amount: 24 },
          { description: '10%対象', rate: BigDecimal('0.1'), net_amount: 469, amount: 46 }
        ],
        receipt_payments: [
          { method: 'cash', amount: 844 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: subtotal 305 + 469 = 774, tax 24 + 46 = 70, total 844。
        expect(result[:resolved]).to include(
          subtotal: 774,
          tax: 70,
          total: 844,
          tax_rate: nil
        )
        expect(result[:needs_review]).to be(false)
        expect(result[:warning_inconsistencies]).to be_empty
        expect(result[:mismatch_codes]).to be_empty
      end
    end

    it 'does not need review for receipt 59 style line-total-only item with matching tax_details' do
      result = call_service(
        receipt: {
          total_amount: 500,
          subtotal_amount: 455,
          tax_amount: 45,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { price: nil, quantity: 1, line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 455,
          tax: 45,
          total: 500,
          tax_rate: BigDecimal('0.1')
        )
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not mark item_total_mismatch when price is nil and quantity is 2 but line_total is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: nil, quantity: 2, line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not mark item_total_mismatch when price and quantity are nil but line_total is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: nil, quantity: nil, line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'fills line_total from price multiplied by quantity when line_total is nil' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 250, quantity: 2, quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:line_total]).to eq(500)
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats blank quantity as one when calculating countable item totals' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 250, quantity: nil, quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0.1') }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:quantity]).to eq(BigDecimal('1'))
        expect(item[:line_total]).to eq(250)
        expect(result[:resolved][:total]).to eq(250)
      end
    end

    it 'keeps discounted line_total derived from original_line_total minus discount_amount' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 300,
            quantity: 2,
            quantity_unit_code: 'each',
            original_line_total: 600,
            discount_amount: 300,
            line_total: 300,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :analysis
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:price]).to eq(300)
        expect(item[:original_line_total]).to eq(600)
        expect(item[:discount_amount]).to eq(300)
        expect(item[:line_total]).to eq(300)
        expect(result[:resolved][:total]).to eq(300)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'converts discount_rate into discount_amount using discount rounding in manual context' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 999,
            quantity: 1,
            quantity_unit_code: 'each',
            discount_rate: BigDecimal('0.105'),
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:original_line_total]).to eq(999)
        expect(item[:discount_amount]).to eq(105)
        expect(item[:line_total]).to eq(894)
        expect(result[:resolved][:total]).to eq(894)
      end
    end

    it 'keeps blank discount_amount nil when no discount is entered in manual context' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 310,
            quantity: 1,
            quantity_unit_code: 'each',
            discount_amount: '',
            discount_rate: '',
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:original_line_total]).to eq(310)
        expect(item[:discount_amount]).to be_nil
        expect(item[:discount_rate]).to be_nil
        expect(item[:line_total]).to eq(310)
        expect(result[:resolved][:total]).to eq(310)
      end
    end

    it 'preserves explicit zero discount_amount in manual context' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 310,
            quantity: 1,
            quantity_unit_code: 'each',
            discount_amount: 0,
            discount_rate: '',
            line_total: nil,
            tax_rate: BigDecimal('0.1'),
            amount_discount_amount_present: true
          }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:original_line_total]).to eq(310)
        expect(item[:discount_amount]).to eq(0)
        expect(item[:discount_rate]).to be_nil
        expect(item[:line_total]).to eq(310)
        expect(result[:resolved][:total]).to eq(310)
      end
    end

    it 'preserves OCR discount_amount in analysis context even when discount_rate is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 271,
            quantity: 1,
            quantity_unit_code: 'each',
            original_line_total: 271,
            discount_amount: 136,
            discount_rate: BigDecimal('0.5'),
            line_total: 135,
            tax_rate: BigDecimal('0.08')
          }
        ],
        context: :analysis,
        tax_rounding_mode: :floor,
        discount_rounding_mode: :floor
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:discount_amount]).to eq(136)
        expect(item[:line_total]).to eq(135)
      end
    end

    it 'keeps AEON-style OCR discount amounts authoritative in analysis context' do
      result = call_service(
        receipt: {
          total_amount: 4_215,
          subtotal_amount: 3_903,
          tax_amount: 312,
          tax_rate: BigDecimal('0.08')
        },
        receipt_items: [
          {
            price: 271,
            quantity: 1,
            quantity_unit_code: 'each',
            original_line_total: 271,
            discount_amount: 136,
            discount_rate: BigDecimal('0.5'),
            line_total: 135,
            tax_rate: BigDecimal('0.08')
          },
          {
            price: 489,
            quantity: 1,
            quantity_unit_code: 'each',
            original_line_total: 489,
            discount_amount: 245,
            discount_rate: BigDecimal('0.5'),
            line_total: 244,
            tax_rate: BigDecimal('0.08')
          },
          {
            price: 432,
            quantity: 1,
            quantity_unit_code: 'each',
            original_line_total: 432,
            discount_amount: 130,
            discount_rate: BigDecimal('0.3'),
            line_total: 302,
            tax_rate: BigDecimal('0.08')
          },
          {
            price: 3_222,
            quantity: 1,
            quantity_unit_code: 'each',
            original_line_total: 3_222,
            discount_amount: 0,
            line_total: 3_222,
            tax_rate: BigDecimal('0.08')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.08'),
            net_amount: 3_903,
            amount: 312
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].sum { |item| item[:line_total] }).to eq(3_903)
        expect(result[:resolved]).to include(
          subtotal: 3_903,
          tax: 312,
          total: 4_215,
          tax_rate: BigDecimal('0.08')
        )
        expect(result[:inconsistencies]).to eq([])
        expect(result[:needs_review]).to be(false)
        expect(result[:calculation_profile]).to eq(
          tax_rounding_mode: :floor,
          discount_rounding_mode: :round,
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_recorded
        )
        expect(result[:calculation_profile_score]).to eq(0)
        expect(result[:calculation_profile_candidates]).to be_present
      end
    end

    it 'keeps external tax details authoritative in edit_save context when line totals are unchanged' do
      result = call_service(
        receipt: {
          total_amount: 4_215,
          subtotal_amount: 3_903,
          tax_amount: 312,
          tax_rate: BigDecimal('0.08')
        },
        receipt_items: [
          { price: 108, quantity: 2, quantity_unit_code: 'each', line_total: 216, tax_rate: BigDecimal('0.08') },
          { price: 271, quantity: 1, quantity_unit_code: 'each', original_line_total: 271, discount_amount: 136, discount_rate: BigDecimal('0.5'), line_total: 135, tax_rate: BigDecimal('0.08') },
          { price: 3_552, quantity: 1, quantity_unit_code: 'each', line_total: 3_552, tax_rate: BigDecimal('0.08') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 3_903, amount: 312, description: '8%対象' }
        ],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 3_903,
          tax: 312,
          total: 4_215,
          tax_rate: BigDecimal('0.08')
        )
        expect(result[:computed]).to include(
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_recorded
        )
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not estimate calculation profile outside analysis context' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 999,
            quantity: 1,
            quantity_unit_code: 'each',
            discount_rate: BigDecimal('0.105'),
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to be_nil
        expect(result[:calculation_profile_score]).to be_nil
        expect(result[:calculation_profile_candidates]).to eq([])
      end
    end

    it 'does not estimate calculation profile in edit_save context' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to be_nil
        expect(result[:calculation_profile_score]).to be_nil
        expect(result[:calculation_profile_candidates]).to eq([])
      end
    end

    it 'edit_saveでは明示されたexternal net source semanticsと現在の丸め設定を使う' do
      result = call_service(
        receipt: {
          receipt_tax_basis: 'tax_added_to_subtotal',
          item_amount_basis: 'line_total_as_net',
          tax_detail_amount_basis: 'net'
        },
        receipt_items: [
          { price: 128, quantity: 2, quantity_unit_code: 'each', line_total: 256, tax_rate: BigDecimal('0.08') },
          { price: 198, quantity: 1, quantity_unit_code: 'each', line_total: 198, tax_rate: BigDecimal('0.08') },
          { price: 115, quantity: 1, quantity_unit_code: 'each', line_total: 115, tax_rate: BigDecimal('0.08') },
          { price: 298, quantity: 1, quantity_unit_code: 'each', line_total: 298, tax_rate: BigDecimal('0.08') },
          { price: 3, quantity: 1, quantity_unit_code: 'each', line_total: 3, tax_rate: BigDecimal('0.10') }
        ],
        context: :edit_save,
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 870, tax: 69, total: 939)
        expect(result[:computed]).to include(
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_net,
          tax_detail_amount_basis: :net
        )
        expect(result[:calculation_profile]).to eq(
          tax_rounding_mode: :floor,
          discount_rounding_mode: :round,
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_net,
          tax_detail_amount_basis: :net
        )
        expect(result.dig(:amount_engine, :selected_basis)).to eq('items_as_tax_excluded')
        expect(result.dig(:computed, :source_items).map { |item| item[:line_total] }).to eq([ 256, 198, 115, 298, 3 ])
        expect(result.dig(:computed, :items).map { |item| item[:line_total] }).to eq([ 276, 213, 124, 321, 3 ])
        expect(result.dig(:amount_engine, :selected_candidate, :computed_items).map { |item| item[:line_total] }).to eq([ 276, 213, 124, 321, 3 ])
      end
    end

    it 'edit_saveではmixed provenanceを保持しつつ保存済みgross itemをrecorded sourceとして扱う' do
      result = call_service(
        receipt: {
          receipt_tax_basis: 'total_includes_tax',
          item_amount_basis: 'mixed_by_tax_rate_group',
          tax_detail_amount_basis: 'gross'
        },
        receipt_items: [
          { price: 140, quantity: 1, quantity_unit_code: 'each', line_total: 140, tax_rate: BigDecimal('0.08') },
          { price: 151, quantity: 1, quantity_unit_code: 'each', line_total: 151, tax_rate: BigDecimal('0.08') },
          { price: 330, quantity: 1, quantity_unit_code: 'each', line_total: 330, tax_rate: BigDecimal('0.10') },
          { price: 490, quantity: 1, quantity_unit_code: 'each', line_total: 490, tax_rate: BigDecimal('0.10') },
          { price: 50, quantity: 1, quantity_unit_code: 'each', line_total: 50, tax_rate: BigDecimal('0') }
        ],
        context: :edit_save,
        tax_rounding_mode: :floor,
        discount_rounding_mode: :round
      )

      aggregate_failures do
        expect(result[:resolved]).to include(subtotal: 1_066, tax: 95, total: 1_161)
        expect(result[:computed]).to include(
          receipt_tax_basis: :total_includes_tax,
          item_amount_basis: :line_total_as_recorded,
          tax_detail_amount_basis: :gross
        )
        expect(result[:calculation_profile]).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(result.dig(:amount_engine, :selected_basis)).to eq('items_as_tax_included')
      end
    end

    it 'applies tax excluded calculation profile when strict external tax evidence is complete' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_100
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(
          receipt_tax_basis: :tax_added_to_subtotal,
          item_amount_basis: :line_total_as_net
        )
        expect(result[:computed]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100,
          item_amount_basis: :line_total_as_net
        )
        expect(result[:resolved]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100
        )
        expect(result[:inconsistencies]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not apply tax excluded calculation profile when candidates are ambiguous' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_101
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :line_total_as_net)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_inconsistencies]).not_to include(:calculation_profile_uncertain)
        expect(result[:computed]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100,
          item_amount_basis: :line_total_as_recorded
        )
        expect(result[:resolved]).to include(
          subtotal: 1_000,
          tax: 100,
          total: 1_100
        )
      end
    end

    it 'does not apply tax excluded calculation profile when printed subtotal tax total are incomplete' do
      result = call_service(
        receipt: {
          total_amount: 1_100
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :line_total_as_net)
        expect(result[:computed]).to include(item_amount_basis: :line_total_as_recorded)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'applies mixed calculation profile when tax rate group assignments exactly match printed amounts' do
      result = call_service(
        receipt: {
          subtotal_amount: 350,
          tax_amount: 28,
          total_amount: 378
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 200, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 },
          { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(result[:computed]).to include(
          subtotal: 350,
          tax: 28,
          total: 378,
          item_amount_basis: :mixed_by_tax_rate_group
        )
        expect(result[:resolved]).to include(
          subtotal: 350,
          tax: 28,
          total: 378
        )
        expect(result[:tax_details]).to include(
          hash_including(rate: BigDecimal('0.08'), net_amount: 100, amount: 8),
          hash_including(rate: BigDecimal('0.1'), net_amount: 200, amount: 20)
        )
        expect(result[:inconsistencies]).to eq([])
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not apply mixed calculation profile when printed subtotal tax total are incomplete' do
      result = call_service(
        receipt: {
          total_amount: 378
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 200, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 },
          { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:calculation_profile]).to include(item_amount_basis: :mixed_by_tax_rate_group)
        expect(result[:computed]).to include(item_amount_basis: :line_total_as_recorded)
        expect(result[:warning_inconsistencies]).to be_empty
        expect(result[:warning_inconsistencies]).not_to include(:calculation_profile_uncertain)
      end
    end

    it 'does not apply same-rate mixed candidates at P3 scope' do
      result = call_service(
        receipt: {
          subtotal_amount: 200,
          tax_amount: 20,
          total_amount: 220
        },
        receipt_items: [
          { line_total: 110, tax_rate: BigDecimal('0.1') },
          { line_total: 100, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 200, amount: 20 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed]).to include(item_amount_basis: :line_total_as_recorded)
        expect(result[:calculation_profile_candidates]).to include(
          hash_including(
            same_rate_item_amount_basis_assignments: contain_exactly(
              hash_including(assignment_scope: :item, item_indices: [ 0 ], basis: :tax_included),
              hash_including(assignment_scope: :item, item_indices: [ 1 ], basis: :tax_excluded)
            )
          )
        )
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_inconsistencies]).not_to include(:calculation_profile_uncertain)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'returns price tax inclusion uncertainty as a warning without requiring review' do
      result = call_service(
        receipt: {
          subtotal_amount: 1_000,
          tax_amount: 100,
          total_amount: 1_101
        },
        receipt_items: [
          {
            price: 1_000,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 1_000,
            tax_rate: BigDecimal('0.1')
          }
        ],
        receipt_tax_details: [
          {
            rate: BigDecimal('0.1'),
            net_amount: 1_000,
            amount: 100,
            description: '外税'
          }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:warning_mismatch_codes]).to include('PRICE_TAX_INCLUSION_UNCERTAIN')
        expect(result[:warning_reasons]).to include('price_tax_inclusion_uncertain')
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'converts 100 percent discount_rate into zero line_total' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 310,
            quantity: 1,
            quantity_unit_code: 'each',
            discount_rate: 100,
            line_total: nil,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:original_line_total]).to eq(310)
        expect(item[:discount_amount]).to eq(310)
        expect(item[:line_total]).to eq(0)
        expect(result[:resolved][:total]).to eq(0)
      end
    end

    it 'keeps explicit zero amount items in manual context' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 0,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 0,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :manual
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:price]).to eq(0)
        expect(item[:line_total]).to eq(0)
        expect(result[:resolved][:total]).to eq(0)
        expect(result[:resolved][:subtotal]).to eq(0)
        expect(result[:resolved][:tax]).to eq(0)
      end
    end

    it 'recalculates manual countable items from zero price even when submitted line_total is stale' do
      result = call_service(
        receipt: {
          total_amount: 1,
          subtotal_amount: 1,
          tax_amount: 0
        },
        receipt_items: [
          {
            price: 0,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 1,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :edit_save
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:price]).to eq(0)
        expect(item[:line_total]).to eq(0)
        expect(result[:resolved][:total]).to eq(0)
        expect(result[:resolved][:subtotal]).to eq(0)
        expect(result[:resolved][:tax]).to eq(0)
      end
    end

    it 'infers discount_rate from OCR discount_amount when rate is missing' do
      result = call_service(
        receipt: {},
        receipt_items: [
          {
            price: 310,
            quantity: 1,
            quantity_unit_code: 'each',
            original_line_total: 310,
            discount_amount: 155,
            line_total: 155,
            tax_rate: BigDecimal('0.1')
          }
        ],
        context: :analysis
      )

      item = result[:computed][:items].first

      aggregate_failures do
        expect(item[:discount_amount]).to eq(155)
        expect(item[:discount_rate]).to eq(BigDecimal('0.5'))
        expect(item[:line_total]).to eq(155)
      end
    end

    it 'fills line_total from price multiplied by decimal quantity when line_total is nil' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'each', line_total: nil, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(4_320)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'parses decimal comma quantity as decimal' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: '0,300', line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit_code: 'each' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(4_320)
      end
    end

    it 'does not fill line_total from price multiplied by quantity for measurement unit' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit_code: 'kilogram' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(0)
        expect(result[:resolved][:total]).not_to eq(4_320)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it 'keeps explicit line_total for measurement unit' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), line_total: 4_320, tax_rate: BigDecimal('0.1'), quantity_unit_code: 'kilogram' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:quantity]).to eq(BigDecimal('0.300'))
        expect(result[:computed][:items].first[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(4_320)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it 'normalizes unknown unit before filling line_total from price multiplied by quantity' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit_code: 'each' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(4_320)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
      end
    end

    it 'parses comma separated amount strings without truncating at the comma' do
      result = call_service(
        receipt: {
          total_amount: '5,000'
        },
        receipt_items: [
          { price: '1,234', quantity: 2, line_total: nil, tax_rate: BigDecimal('0.1'), quantity_unit_code: 'each' },
          { price: nil, quantity: 1, line_total: '4,320', tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:computed][:items].first[:line_total]).to eq(2_468)
        expect(result[:computed][:items].second[:line_total]).to eq(4_320)
        expect(result[:resolved][:total]).to eq(6_788)
      end
    end

    it 'parses comma separated receipt total as yen amount when no items exist' do
      result = call_service(
        receipt: {
          total_amount: '5,000'
        },
        receipt_items: [],
        context: :manual
      )

      expect(result[:resolved][:total]).to eq(5_000)
    end

    it 'marks item_total_mismatch when price multiplied by quantity clearly conflicts with line_total' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 300, quantity: 2, line_total: 500, tax_rate: BigDecimal('0.1'), quantity_unit_code: 'each' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'does not mark item_total_mismatch for measurement unit when line_total conflicts with price times quantity' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 14_400, quantity: BigDecimal('0.300'), quantity_unit_code: 'kilogram', line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'marks item_total_mismatch for normalized unknown unit when line_total conflicts with price times quantity' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 300, quantity: 2, quantity_unit_code: 'each', line_total: 500, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'does not mark item_total_mismatch when price appears tax-exclusive and line_total is tax-included' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 100, quantity: 1, line_total: 110, tax_rate: BigDecimal('0.1'), quantity_unit_code: 'each' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(110)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'marks insufficient_data when neither line_total nor price is present' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: nil, quantity: 1, line_total: nil, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:inconsistencies]).to include(:insufficient_data)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'does not need review for an explicit zero amount item' do
      result = call_service(
        receipt: {
          total_amount: 0,
          subtotal_amount: 0,
          tax_amount: 0
        },
        receipt_items: [
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(0)
        expect(result[:inconsistencies]).not_to include(:insufficient_data)
        expect(result[:warning_inconsistencies]).not_to include(:zero_amount_item_incomplete)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats zero line_total without price and quantity as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 0,
          subtotal_amount: 0,
          tax_amount: 0
        },
        receipt_items: [
          { price: nil, quantity: nil, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:zero_amount_item_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:insufficient_data)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not need review for normal items mixed with zero amount items' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { price: 500, quantity: 1, line_total: 500, tax_rate: BigDecimal('0.1') },
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') },
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(500)
        expect(result[:inconsistencies]).not_to include(:insufficient_data)
        expect(result[:inconsistencies]).not_to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'does not need review when only zero amount items exist and receipt total is zero' do
      result = call_service(
        receipt: {
          total_amount: 0,
          subtotal_amount: 0,
          tax_amount: 0
        },
        receipt_items: [
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved][:total]).to eq(0)
        expect(result[:blocking_inconsistencies]).to be_empty
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'marks blocking mismatch when only zero amount items exist but receipt total is positive' do
      result = call_service(
        receipt: {
          total_amount: 500,
          subtotal_amount: 455,
          tax_amount: 45,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { price: 0, quantity: 1, line_total: 0, tax_rate: BigDecimal('0.1') }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:blocking_inconsistencies]).to include(:item_total_mismatch)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'treats tax_detail with missing net_amount as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: nil, amount: 9 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats tax_detail with missing amount as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 99, amount: nil }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats tax_detail with missing rate as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: nil, net_amount: 99, amount: 9 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_incomplete)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats clearly partial tax_details as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 218,
          subtotal_amount: 200,
          tax_amount: 18,
          tax_rate: nil
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.08') },
          { line_total: 110, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 100, amount: 8 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:tax_detail_partial)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'native engineではpartial tax_detailsでitem_totalが大きい混在疑いをreview_neededにする' do
      result = call_service(
        receipt: {
          tax_rate: nil
        },
        receipt_items: [
          { line_total: 130, tax_rate: BigDecimal('0.08') },
          { line_total: 140, tax_rate: BigDecimal('0.08') },
          { line_total: 300, tax_rate: BigDecimal('0.1') },
          { line_total: 490, tax_rate: BigDecimal('0.1') },
          { line_total: 50, tax_rate: nil }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 270, amount: 21 },
          { rate: BigDecimal('0.1'), net_amount: 300, amount: 30 }
        ],
        context: :analysis
      )

      aggregate_failures do
        # 検算: 明細合計は1,110円。partial TaxDetailsだけで 270+21 + 300+30 = 621円へは解決しない。
        # 税内訳が一部欠け、税抜/税込混在疑いが残るため、現行Recify方針ではreview_neededにする。
        expect(result[:resolved][:total]).to eq(1_110)
        expect(result[:resolved][:total]).not_to eq(621)
        expect(result[:resolved][:tax_rate]).to be_nil
        expect(result[:computed][:item_amount_basis]).to eq(:line_total_as_recorded)
        expect(result[:calculation_profile]).not_to include(item_amount_basis: :line_total_as_net)
        expect(result[:calculation_profile_candidates].map { |candidate| candidate[:profile][:item_amount_basis] }).to include(:mixed_by_tax_rate_group)
        expect(result[:warning_inconsistencies]).to include(:tax_detail_partial)
        expect(result[:warning_inconsistencies]).to include(:price_tax_inclusion_uncertain)
        expect(result[:blocking_inconsistencies]).not_to include(:tax_detail_mismatch)
        expect(result[:review_reasons]).to include('price_tax_inclusion_uncertain')
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'keeps complete and clearly conflicting tax_details as blocking mismatch' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9,
          tax_rate: BigDecimal('0.1')
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 78, amount: 30 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:blocking_inconsistencies]).to include(:tax_detail_mismatch)
        expect(result[:needs_review]).to be(true)
      end
    end

    it 'treats item tax rate group uncertainty as warning without blocking review' do
      result = call_service(
        receipt: {
          total_amount: 108,
          subtotal_amount: 99,
          tax_amount: 9
        },
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.08'), net_amount: 99, amount: 9 }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:warning_inconsistencies]).to include(:item_tax_rate_group_uncertain)
        expect(result[:warning_reasons]).to include('item_tax_rate_group_uncertain')
        expect(result[:blocking_inconsistencies]).not_to include(:item_tax_rate_group_uncertain)
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'treats item net total plus tax_details as external tax when receipt total matches net plus tax' do
      result = call_service(
        receipt: {
          total_amount: 500
        },
        receipt_items: [
          { line_total: 455, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 455, amount: 45, description: '外税 10%' }
        ],
        context: :analysis
      )

      aggregate_failures do
        expect(result[:resolved]).to include(
          subtotal: 455,
          tax: 45,
          total: 500,
          tax_rate: BigDecimal('0.1')
        )
        expect(result[:needs_review]).to be(false)
      end
    end

    it 'prefers item calculation over tax_details in edit_save context when items exist' do
      result = call_service(
        receipt: {},
        receipt_items: [
          { line_total: 108, tax_rate: BigDecimal('0.1') }
        ],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :edit_save
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(99)
        expect(result[:resolved][:tax]).to eq(9)
        expect(result[:resolved][:total]).to eq(108)
      end
    end

    it 'uses tax_details in manual context when no items exist' do
      result = call_service(
        receipt: {},
        receipt_items: [],
        receipt_tax_details: [
          { rate: BigDecimal('0.1'), net_amount: 1_000, amount: 100 }
        ],
        context: :manual
      )

      aggregate_failures do
        expect(result[:resolved][:subtotal]).to eq(1_000)
        expect(result[:resolved][:tax]).to eq(100)
        expect(result[:resolved][:total]).to eq(1_100)
        expect(result[:resolved][:tax_rate]).to eq(BigDecimal('0.1'))
      end
    end
  end
end
