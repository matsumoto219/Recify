require 'rails_helper'
require 'zlib'

RSpec.describe Receipt, type: :model do
  it 'lock_versionで楽観ロックを使う' do
    receipt = create(:receipt)

    expect(receipt.reload.lock_version).to eq(0)
  end

  it '古いReceipt instanceからの更新を拒否する' do
    receipt = create(:receipt)
    current = described_class.find(receipt.id)
    stale = described_class.find(receipt.id)
    current.update!(memo: '先に保存')

    expect do
      stale.update!(memo: '古い保存')
    end.to raise_error(ActiveRecord::StaleObjectError)
  end

  include ActiveSupport::Testing::TimeHelpers

  def png_bytes(width:, height:, minimum_byte_size: nil)
    chunk = lambda do |type, data|
      [ data.bytesize ].pack('N') + type + data + [ Zlib.crc32(type + data) ].pack('N')
    end
    header = [ width, height, 8, 2, 0, 0, 0 ].pack('NNCCCCC')
    row = "\x00".b + ("\xFF\xFF\xFF".b * width)
    compressed = Zlib::Deflate.deflate(row * height)

    png = "\x89PNG\r\n\x1A\n".b +
      chunk.call('IHDR'.b, header) +
      chunk.call('IDAT'.b, compressed) +
      chunk.call('IEND'.b, ''.b)
    return png if minimum_byte_size.blank? || png.bytesize >= minimum_byte_size

    png + ("\0".b * (minimum_byte_size - png.bytesize))
  end

  def attach_png(receipt, width:, height:, filename: "receipt-#{width}x#{height}.png", content_type: 'image/png', minimum_byte_size: nil)
    receipt.image.attach(
      io: StringIO.new(png_bytes(width: width, height: height, minimum_byte_size: minimum_byte_size)),
      filename: filename,
      content_type: content_type
    )
  end

  def count_sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      name = payload[:name].to_s
      sql = payload[:sql].to_s
      next if %w[SCHEMA TRANSACTION CACHE].include?(name)
      next if sql.match?(/\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      queries << sql
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      yield
    end

    queries
  end

  describe 'associations' do
    it 'destroy時に解析run履歴を削除する' do
      receipt = create(:receipt)
      run = create(:receipt_analysis_run, :succeeded, receipt:)

      receipt.destroy!

      expect(described_class.exists?(receipt.id)).to be(false)
      expect(ReceiptAnalysisRun.exists?(run.id)).to be(false)
    end
  end

  describe 'moderation status' do
    it 'defaultは通常表示でユーザー画面の対象になる' do
      receipt = create(:receipt)

      aggregate_failures do
        expect(receipt).to be_moderation_active
        expect(receipt).to be_active_for_user
        expect(described_class.active_for_user).to include(receipt)
      end
    end

    it '隔離中のreceiptをユーザー画面scopeから除外する' do
      active = create(:receipt)
      quarantined = create(:receipt, :quarantined)

      aggregate_failures do
        expect(quarantined).to be_quarantined
        expect(described_class.active_for_user).to include(active)
        expect(described_class.active_for_user).not_to include(quarantined)
      end
    end

    it 'quarantine!で隔離情報を保存し、release_quarantine!で通常表示に戻す' do
      actor = create(:user, :admin)
      receipt = create(:receipt, purchased_at: Time.zone.parse('2026-06-23 11:00:00'))
      event = create(:security_event)

      travel_to(Time.zone.parse('2026-06-23 12:00:00')) do
        receipt.quarantine!(actor: actor, reason: 'policy violation', source_security_event: event)

        aggregate_failures 'quarantine' do
          expect(receipt).to be_quarantined
          expect(receipt.quarantined_by).to eq(actor)
          expect(receipt.quarantine_reason).to eq('policy violation')
          expect(receipt.quarantine_source_security_event).to eq(event)
          expect(receipt.quarantine_released_at).to be_nil
        end
      end

      travel_to(Time.zone.parse('2026-06-23 13:00:00')) do
        receipt.release_quarantine!(actor: actor, reason: 'false positive')

        aggregate_failures 'release' do
          expect(receipt).to be_moderation_active
          expect(receipt.quarantine_released_by).to eq(actor)
          expect(receipt.quarantine_released_reason).to eq('false positive')
          expect(receipt.quarantined_at).to be_present
          expect(receipt.quarantine_reason).to eq('policy violation')
        end
      end
    end

    it '隔離状態には隔離理由と実行者が必要' do
      receipt = build(:receipt, moderation_status: Receipt::MODERATION_STATUS_QUARANTINED)

      aggregate_failures do
        expect(receipt).not_to be_valid
        expect(receipt.errors[:quarantined_at]).to be_present
        expect(receipt.errors[:quarantined_by]).to be_present
        expect(receipt.errors[:quarantine_reason]).to be_present
      end
    end
  end

  describe 'amount limit validation' do
    def configure_amount_limits(total:, item_price:, item_line_total:, tax:, adjustment:, payment:)
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(item_price))
      create(:system_setting, key: 'limits.receipt_item_line_total_max', value: SystemSettings.stored_value(item_line_total))
      create(:system_setting, key: 'limits.receipt_tax_amount_max', value: SystemSettings.stored_value(tax))
      create(:system_setting, key: 'limits.receipt_adjustment_amount_max', value: SystemSettings.stored_value(adjustment))
      create(:system_setting, key: 'limits.receipt_payment_amount_max', value: SystemSettings.stored_value(payment))
      create(:system_setting, key: 'limits.receipt_total_amount_max', value: SystemSettings.stored_value(total))
    end

    it 'SystemSettingsのレシート金額上限を参照する' do
      configure_amount_limits(total: 500, item_price: 500, item_line_total: 500, tax: 100, adjustment: 50, payment: 500)

      receipt = build(:receipt, total_amount: 501, subtotal_amount: 501, tax_amount: 101, tip_amount: 51)

      aggregate_failures do
        expect(receipt).not_to be_valid
        expect(receipt.errors[:total_amount]).to be_present
        expect(receipt.errors[:subtotal_amount]).to be_present
        expect(receipt.errors[:tax_amount]).to be_present
        expect(receipt.errors[:tip_amount]).to be_present
      end
    end
  end

  describe '#review_reason_labels' do
    it 'ユーザー向けに許可されたreview_reasonだけを表示する' do
      receipt = build(
        :receipt,
        review_reasons: [
          'item_name_uncertain',
          'ai_timeout',
          'unknown_reason'
        ]
      )

      expect(receipt.review_reason_labels).to eq([
        I18n.t('enums.receipt_item.review_reason.item_name_uncertain')
      ])
    end
  end

  describe '.summary_for' do
    it 'user scopeを適用しstatus別件数を返す' do
      user = create(:user)
      other_user = create(:user, email: 'summary-other@example.com')
      create(:receipt, :completed, user: user)
      create(:receipt, :processing, :with_image, user: user)
      create(:receipt, :review_needed, user: user)
      create(:receipt, :failed, user: user)
      create(:receipt, :failed, user: user)
      create(:receipt, :failed, user: other_user)

      summary = described_class.summary_for(user)

      aggregate_failures do
        expect(summary[:receipts_count]).to eq(5)
        expect(summary[:processing_count]).to eq(1)
        expect(summary[:review_needed_count]).to eq(1)
        expect(summary[:failed_count]).to eq(2)
      end
    end

    it 'completed / review_needed のみを金額KPIに含める' do
      user = create(:user)

      create(:receipt, :completed, user:, total_amount: 1000)
      create(:receipt, :review_needed, user:, total_amount: 2000)
      create(:receipt, :processing, :with_image, user:, total_amount: 3000)
      create(:receipt, :failed, user:, total_amount: 4000)

      summary = described_class.summary_for(user)

      aggregate_failures do
        expect(summary[:current_month_total]).to eq(3000)
        expect(summary[:overall_total]).to eq(3000)
      end
    end

    it 'empty scope returns zero summary values' do
      user = create(:user)

      summary = described_class.summary_for(user, scope: described_class.none)

      aggregate_failures do
        expect(summary[:receipts_count]).to eq(0)
        expect(summary[:current_month_total]).to eq(0)
        expect(summary[:previous_month_total]).to eq(0)
        expect(summary[:overall_total]).to eq(0)
        expect(summary[:processing_count]).to eq(0)
        expect(summary[:review_needed_count]).to eq(0)
        expect(summary[:failed_count]).to eq(0)
      end
    end

    it '今月/先月の金額差分を対象statusだけで計算する' do
      user = create(:user)
      current_month = Time.zone.local(2026, 5, 16, 12, 0, 0)
      previous_month = Time.zone.local(2026, 4, 16, 12, 0, 0)

      travel_to(current_month) do
        create(:receipt, :completed, user:, total_amount: 2000, purchased_at: current_month)
        create(:receipt, :review_needed, user:, total_amount: 1000, purchased_at: current_month)
        create(:receipt, :failed, user:, total_amount: 9000, purchased_at: current_month)
        create(:receipt, :completed, user:, total_amount: 1500, purchased_at: previous_month)

        summary = described_class.summary_for(user)

        aggregate_failures do
          expect(summary[:current_month_total]).to eq(3000)
          expect(summary[:previous_month_total]).to eq(1500)
          expect(summary[:monthly_change_label]).to eq(I18n.t('dashboard.summary.amount.monthly_change', value: '+100'))
          expect(summary[:monthly_change_icon]).to eq('trending_up')
        end
      end
    end

    it 'summary aggregates are loaded with one receipt query per call' do
      user = create(:user)
      create(:receipt, :completed, user:, total_amount: 1000)
      create(:receipt, :processing, :with_image, user:, total_amount: 2000)
      create(:receipt, :failed, user:, total_amount: 3000)

      summary = nil
      queries = count_sql_queries do
        summary = described_class.summary_for(user)
      end
      receipt_queries = queries.select { |sql| sql.include?('FROM "receipts"') }

      aggregate_failures do
        expect(receipt_queries.size).to eq(1)
        expect(summary[:receipts_count]).to eq(3)
        expect(summary[:current_month_total]).to eq(1000)
        expect(summary[:overall_total]).to eq(1000)
        expect(summary[:processing_count]).to eq(1)
        expect(summary[:failed_count]).to eq(1)
      end
    end

    it 'repeated summary calls avoid the previous seven-query aggregate pattern' do
      user = create(:user)
      create(:receipt, :completed, user:, total_amount: 1000)
      create(:receipt, :review_needed, user:, total_amount: 2000)

      queries = count_sql_queries do
        2.times { described_class.summary_for(user) }
      end
      receipt_queries = queries.select { |sql| sql.include?('FROM "receipts"') }

      expect(receipt_queries.size).to eq(2)
    end
  end

  describe '.category_summary_for' do
    def create_item(receipt, category:, line_total:, name: '商品')
      receipt.receipt_items.create!(
        raw_text: name,
        confirmed_name: name,
        category: category,
        quantity: 1,
        price: line_total,
        line_total: line_total,
        position_index: receipt.receipt_items.count + 1
      )
    end

    it 'completed / review_needed の明細だけカテゴリ別に金額と件数を集計する' do
      user = create(:user)
      completed = create(:receipt, :completed, user:)
      review_needed = create(:receipt, :review_needed, user:)
      processing = create(:receipt, :processing, :with_image, user:)
      failed = create(:receipt, :failed, user:)

      create_item(completed, category: 'food', line_total: 500)
      create_item(completed, category: 'food', line_total: 700)
      create_item(review_needed, category: 'drink', line_total: 300)
      create_item(processing, category: 'food', line_total: 9_999)
      create_item(failed, category: 'drink', line_total: 9_999)

      summary = described_class.category_summary_for(user)

      aggregate_failures do
        expect(summary).to include(
          hash_including(category: 'food', label: '食品', total_amount: 1200, item_count: 2),
          hash_including(category: 'drink', label: '飲料', total_amount: 300, item_count: 1)
        )
        expect(summary.map { |entry| entry[:total_amount] }.sum).to eq(1500)
      end
    end

    it 'user scopeを適用する' do
      user = create(:user)
      other_user = create(:user)
      receipt = create(:receipt, :completed, user:)
      other_receipt = create(:receipt, :completed, user: other_user)

      create_item(receipt, category: 'food', line_total: 500)
      create_item(other_receipt, category: 'food', line_total: 10_000)

      summary = described_class.category_summary_for(user)

      expect(summary).to contain_exactly(hash_including(category: 'food', total_amount: 500, item_count: 1))
    end

    it 'nil / blank category は uncategorized として扱い、other は other のまま扱う' do
      user = create(:user)
      receipt = create(:receipt, :completed, user:)

      create_item(receipt, category: nil, line_total: 100)
      create_item(receipt, category: '', line_total: 200)
      create_item(receipt, category: 'other', line_total: 300)

      summary = described_class.category_summary_for(user)

      aggregate_failures do
        expect(summary).to include(hash_including(category: 'uncategorized', label: I18n.t('receipts.item_fields.uncategorized'), total_amount: 300, item_count: 2))
        expect(summary).to include(hash_including(category: 'other', label: 'その他', total_amount: 300, item_count: 1))
      end
    end

    it '検索scope内で集計できる' do
      user = create(:user)
      coffee_receipt = create(:receipt, :completed, user:, store_name: 'コーヒーストア')
      grocery_receipt = create(:receipt, :completed, user:, store_name: '食品ストア')

      create_item(coffee_receipt, category: 'drink', line_total: 450, name: 'コーヒー')
      create_item(grocery_receipt, category: 'food', line_total: 800, name: 'パン')

      scope = Receipts::SearchQuery.call(scope: user.receipts, query: 'コーヒー')
      summary = described_class.category_summary_for(user, scope:)

      expect(summary).to contain_exactly(hash_including(category: 'drink', total_amount: 450, item_count: 1))
    end
  end

  describe '.search' do
    let(:user) { create(:user) }

    def create_search_receipt(user:, store_name:, total_amount:, purchased_at:, item_name: nil)
      receipt = create(
        :receipt,
        :completed,
        user: user,
        store_name: store_name,
        total_amount: total_amount,
        purchased_at: purchased_at
      )

      if item_name.present?
        receipt.receipt_items.create!(
          raw_text: item_name,
          confirmed_name: item_name,
          category: "food",
          quantity: 1,
          quantity_unit_code: "each",
          price: total_amount,
          line_total: total_amount,
          position_index: 1
        )
      end

      receipt
    end

    it 'subquery用途のmatching idsには既存orderを持ち込まない' do
      sql = Receipts::SearchQuery.call(
        scope: described_class.order(created_at: :desc),
        query: 'コーヒー'
      ).to_sql

      aggregate_failures do
        expect(sql).to include('ORDER BY "receipts"."created_at" DESC')
        expect(sql.scan(/ORDER BY/).size).to eq(1)
      end
    end

    it 'スペース区切りのtokenをAND条件として検索する' do
      target = create_search_receipt(
        user: user,
        store_name: 'サンプルコンビニ渋谷店',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      create_search_receipt(
        user: user,
        store_name: 'サンプルコンビニ渋谷店',
        total_amount: 1500,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      create_search_receipt(
        user: user,
        store_name: 'サンプルストア銀座店',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )

      expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'サンプルコンビニ 1000')).to contain_exactly(target)
    end

    it '金額比較演算子でtotal_amountを検索する' do
      low = create_search_receipt(
        user: user,
        store_name: '低額ストア',
        total_amount: 800,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      exact = create_search_receipt(
        user: user,
        store_name: '一致ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      high = create_search_receipt(
        user: user,
        store_name: '高額ストア',
        total_amount: 1200,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )

      aggregate_failures do
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: '<=1000')).to contain_exactly(low, exact)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: '>=1000')).to contain_exactly(exact, high)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'amount<=1000')).to contain_exactly(low, exact)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'total>=1000')).to contain_exactly(exact, high)
      end
    end

    it '明細名tokenと金額演算子をAND検索する' do
      target = create_search_receipt(
        user: user,
        store_name: '牛乳対象ストア',
        total_amount: 280,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0),
        item_name: '牛乳'
      )
      create_search_receipt(
        user: user,
        store_name: '牛乳高額ストア',
        total_amount: 480,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0),
        item_name: '牛乳'
      )
      create_search_receipt(
        user: user,
        store_name: 'パン対象ストア',
        total_amount: 280,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0),
        item_name: 'パン'
      )

      expect(Receipts::SearchQuery.call(scope: user.receipts, query: '牛乳 <=300')).to contain_exactly(target)
    end

    it '日付tokenとdate演算子で購入日を検索する' do
      january_10 = create_search_receipt(
        user: user,
        store_name: '一月十日ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      january_20 = create_search_receipt(
        user: user,
        store_name: '一月二十日ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 20, 12, 0, 0)
      )
      february = create_search_receipt(
        user: user,
        store_name: '二月ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 2, 1, 12, 0, 0)
      )

      aggregate_failures do
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: '2026-01-10')).to contain_exactly(january_10)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'date>=2026-01-15')).to contain_exactly(january_20, february)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'date<=2026-01-10')).to contain_exactly(january_10)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'date:2026-01-01..2026-01-31')).to contain_exactly(january_10, january_20)
      end
    end

    it '不正なdate演算子でも例外を出さずマッチなしにする' do
      create_search_receipt(
        user: user,
        store_name: '日付安全化ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )

      invalid_queries = [
        'date>=2026-13-01',
        'date>=2026-02-31',
        'date<=2214-15-99',
        'date:2026-01-01..2026-13-40'
      ]
      partial_queries = [
        'date:2026-01-01..',
        'date>=2026-'
      ]

      aggregate_failures do
        (invalid_queries + partial_queries).each do |query|
          expect { Receipts::SearchQuery.call(scope: user.receipts, query: query).load }.not_to raise_error
          expect(Receipts::SearchQuery.call(scope: user.receipts, query: query)).to be_empty
        end
      end
    end

    it '複数date条件をAND検索し、矛盾条件は0件にする' do
      january_10 = create_search_receipt(
        user: user,
        store_name: '一月十日ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      january_20 = create_search_receipt(
        user: user,
        store_name: '一月二十日ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 1, 20, 12, 0, 0)
      )
      february = create_search_receipt(
        user: user,
        store_name: '二月ストア',
        total_amount: 1000,
        purchased_at: Time.zone.local(2026, 2, 1, 12, 0, 0)
      )

      aggregate_failures do
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'date>=2026-01-01 date<=2026-01-31')).to contain_exactly(january_10, january_20)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'date>=2026-01-15 date>=2026-02-01')).to contain_exactly(february)
        expect(Receipts::SearchQuery.call(scope: user.receipts, query: 'date>=2026-02-01 date<=2026-01-31')).to be_empty
      end
    end

    it '店舗名・金額・日付の複合条件をAND検索する' do
      target = create_search_receipt(
        user: user,
        store_name: 'サンプルコンビニ渋谷店',
        total_amount: 900,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      create_search_receipt(
        user: user,
        store_name: 'サンプルコンビニ渋谷店',
        total_amount: 1500,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )
      create_search_receipt(
        user: user,
        store_name: 'サンプルコンビニ渋谷店',
        total_amount: 900,
        purchased_at: Time.zone.local(2025, 12, 31, 12, 0, 0)
      )
      create_search_receipt(
        user: user,
        store_name: 'サンプルストア銀座店',
        total_amount: 900,
        purchased_at: Time.zone.local(2026, 1, 10, 12, 0, 0)
      )

      expect(
        Receipts::SearchQuery.call(
          scope: user.receipts,
          query: 'サンプルコンビニ <=1000 date>=2026-01-01'
        )
      ).to contain_exactly(target)
    end
  end

  describe 'image validation' do
    it 'WebP画像を対応外形式として弾く' do
      receipt = build(:receipt)
      receipt.image.attach(
        io: StringIO.new('webp image'),
        filename: 'receipt.webp',
        content_type: 'image/webp'
      )

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end

    it 'テキスト/HTML/JSをJPEGに偽装しても実体検査で拒否する' do
      disguised_files = {
        text: 'plain text receipt',
        html: '<html><body>not an image</body></html>',
        javascript: 'alert("not an image")'
      }

      disguised_files.each do |label, body|
        receipt = build(:receipt, status: 'processing')
        receipt.image.attach(
          io: StringIO.new(body),
          filename: "#{label}.jpg",
          content_type: 'image/jpeg'
        )

        aggregate_failures label do
          expect(receipt).not_to be_valid
          expect(receipt.errors.of_kind?(:image, :invalid_content_type)).to be(true)
        end
      end
    end

    it 'PDFをJPEGに偽装しても拒否する' do
      receipt = build(:receipt, status: 'processing')
      receipt.image.attach(
        io: StringIO.new("%PDF-1.7\nnot a receipt image"),
        filename: 'receipt.jpg',
        content_type: 'image/jpeg'
      )

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end

    it 'SVGをPNGに偽装しても拒否する' do
      receipt = build(:receipt, status: 'processing')
      receipt.image.attach(
        io: StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'),
        filename: 'receipt.png',
        content_type: 'image/png'
      )

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end

    it '拡張子なしでも実体が正常PNGなら許可する' do
      receipt = build(:receipt, status: 'processing')
      attach_png(receipt, width: 120, height: 120, filename: 'receipt', content_type: nil)

      expect(receipt).to be_valid
    end

    it 'content_typeがtext/plainでも実体が正常PNGなら許可する' do
      receipt = build(:receipt, status: 'processing')
      attach_png(receipt, width: 120, height: 120, filename: 'receipt.txt', content_type: 'text/plain')

      expect(receipt).to be_valid
    end

    it '拡張子なしの非画像は拒否する' do
      receipt = build(:receipt, status: 'processing')
      receipt.image.attach(
        io: StringIO.new('not image'),
        filename: 'receipt',
        content_type: nil
      )

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end

    it 'metadataにwidth/heightがなくても実画像から小さすぎるPNGを拒否する' do
      receipt = build(:receipt, status: 'processing')
      attach_png(receipt, width: 1, height: 1)

      aggregate_failures do
        expect(receipt.image.blob.metadata).not_to include('width', 'height')
        expect(receipt).not_to be_valid
        expect(receipt.errors.of_kind?(:image, :image_too_small)).to be(true)
      end
    end

    it 'metadataにwidth/heightがなくても十分なdimensionのPNGを許可する' do
      receipt = build(:receipt, status: 'processing')
      attach_png(receipt, width: 120, height: 120)

      aggregate_failures do
        expect(receipt.image.blob.metadata).not_to include('width', 'height')
        expect(receipt).to be_valid
      end
    end

    it 'metadataのdimensionが大きすぎる画像を拒否する' do
      receipt = build(:receipt, status: 'processing')
      attach_png(receipt, width: 120, height: 120)
      receipt.image.blob.metadata['width'] = Receipt::MAX_IMAGE_DIMENSION + 1
      receipt.image.blob.metadata['height'] = 120

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :image_too_large)).to be(true)
    end

    it '実画像のdimensionが大きすぎる場合も拒否する' do
      receipt = build(:receipt, status: 'processing')
      attach_png(receipt, width: Receipt::MAX_IMAGE_DIMENSION + 1, height: 120)

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :image_too_large)).to be(true)
    end

    it '20MBを超える画像は拒否する' do
      receipt = build(:receipt, status: 'processing')
      attach_png(
        receipt,
        width: 120,
        height: 120,
        minimum_byte_size: Receipt::MAX_FILE_SIZE + 1
      )

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :file_too_large)).to be(true)
    end

    it '壊れた画像は安全側で拒否する' do
      receipt = build(:receipt, status: 'processing')
      receipt.image.attach(
        io: StringIO.new('not image'),
        filename: 'broken.png',
        content_type: 'image/png'
      )

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end

    it 'JPEGとして送られたSVG偽装画像を引き続き拒否する' do
      receipt = build(:receipt, status: 'processing')
      receipt.image.attach(
        io: StringIO.new('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'),
        filename: 'evil.jpg',
        content_type: 'image/jpeg'
      )

      expect(receipt).not_to be_valid
      expect(receipt.errors.of_kind?(:image, :invalid_content_type)).to be(true)
    end
  end

  describe 'image retention state' do
    it 'keep_imageは初期値trueにする' do
      receipt = create(:receipt)

      expect(receipt.keep_image).to be(true)
    end

    it '画像保持無効状態を返す' do
      receipt = build(:receipt, keep_image: false)

      expect(receipt).to be_image_retention_disabled
    end

    it 'purge予定を記録する' do
      receipt = create(:receipt, keep_image: false)
      eligible_at = Time.zone.parse('2026-06-03 21:00:00')

      receipt.schedule_image_purge!(eligible_at: eligible_at)

      aggregate_failures do
        expect(receipt.reload.image_purge_eligible_at).to eq(eligible_at)
        expect(receipt.image_purged_at).to be_nil
        expect(receipt.image_purged_reason).to be_nil
      end
    end

    it '手動purge済み状態を返す' do
      receipt = create(:receipt)
      purged_at = Time.zone.parse('2026-06-03 22:00:00')

      receipt.mark_image_purged!(
        reason: Receipt::IMAGE_PURGED_REASON_MANUAL_DELETE,
        purged_at: purged_at
      )

      aggregate_failures do
        expect(receipt.reload).to be_image_purged
        expect(receipt).to be_image_purged_manually
        expect(receipt).not_to be_image_purged_by_system
        expect(receipt.image_purged_at).to eq(purged_at)
      end
    end

    it 'system purge済み状態を返す' do
      receipt = create(:receipt)

      receipt.mark_image_purged!(reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE)

      aggregate_failures do
        expect(receipt.reload).to be_image_purged
        expect(receipt).to be_image_purged_by_system
      end
    end

    it '画像purge済みのreview_neededは部分OCRデータとして許可する' do
      receipt = build(
        :receipt,
        :review_needed,
        store_name: nil,
        total_amount: nil,
        payment_method: nil,
        image_purged_at: Time.current,
        image_purged_reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE
      )

      expect(receipt).to be_valid
    end

    it '画像purge済みでもprocessingは画像必須のままにする' do
      receipt = build(
        :receipt,
        :processing,
        image_purged_at: Time.current,
        image_purged_reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE
      )

      aggregate_failures do
        expect(receipt).not_to be_valid
        expect(receipt.errors.of_kind?(:image, :blank)).to be(true)
      end
    end

    it '未知のpurge reasonは拒否する' do
      receipt = create(:receipt)

      expect {
        receipt.mark_image_purged!(reason: 'unknown')
      }.to raise_error(ArgumentError, 'Unknown image_purged_reason=unknown')
    end
  end

  describe 'public/display identifiers' do
    it '作成時にpublic_idとdisplay_idを自動生成する' do
      receipt = create(:receipt)

      aggregate_failures do
        expect(receipt.public_id).to match(/\Arcpt_[A-Za-z0-9]{16}\z/)
        expect(receipt.display_id).to match(/\AR-[0-9A-Z]{6}\z/)
      end
    end

    it 'factory経由でもpublic_idとdisplay_idを生成する' do
      receipt = create(:receipt)

      aggregate_failures do
        expect(receipt.public_id).to be_present
        expect(receipt.display_id).to be_present
      end
    end

    it 'public_idは全ユーザー横断でuniqueにする' do
      receipt = create(:receipt)
      duplicate = build(:receipt, public_id: receipt.public_id)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:public_id]).to be_present
    end

    it 'public_id生成時に既存値との衝突を避ける' do
      duplicate_random = 'ABCDEFGHJKLMNPQR'
      unique_random = 'STUVWXYZabcdefgh'
      create(:receipt, public_id: "rcpt_#{duplicate_random}")

      allow(SecureRandom).to receive(:base58).and_return(duplicate_random, unique_random)

      receipt = create(:receipt)

      expect(receipt.public_id).to eq("rcpt_#{unique_random}")
    end

    it 'display_idは同一ユーザー内だけuniqueにする' do
      user = create(:user)
      other_user = create(:user, email: 'display-id-other@example.com')
      receipt = create(:receipt, user:)

      same_user_duplicate = build(:receipt, user:, display_id: receipt.display_id)
      other_user_duplicate = build(:receipt, user: other_user, display_id: receipt.display_id)

      aggregate_failures do
        expect(same_user_duplicate).not_to be_valid
        expect(same_user_duplicate.errors[:display_id]).to be_present
        expect(other_user_duplicate).to be_valid
      end
    end

    it 'display_id生成時に同一ユーザー内の既存値との衝突を避ける' do
      user = create(:user)
      create(:receipt, user:, display_id: 'R-000001')

      allow(SecureRandom).to receive(:random_number).and_call_original
      allow(SecureRandom).to receive(:random_number).with(36**described_class::DISPLAY_ID_RANDOM_LENGTH).and_return(1, 2)

      receipt = create(:receipt, user:)

      expect(receipt.display_id).to eq('R-000002')
    end

    it 'to_paramはpublic_idを返す' do
      receipt = create(:receipt)

      expect(receipt.to_param).to eq(receipt.public_id)
    end

    it 'DOM targetはpublic_idベースにする' do
      receipt = create(:receipt)

      aggregate_failures do
        expect(receipt.dom_target_id).to eq("receipt_#{receipt.public_id}")
        expect(receipt.dom_target_id).not_to eq("receipt_#{receipt.id}")
      end
    end
  end

  describe 'country_region normalization' do
    it 'blank country_region は手動登録向けに JPN を既定値にする' do
      receipt = build(:receipt, country_region: nil)

      receipt.valid?

      expect(receipt.country_region).to eq('JPN')
    end

    it 'country_region はuppercaseに正規化し、2文字コードは内部保存で無効にする' do
      receipt = build(:receipt, country_region: ' jp ')

      receipt.valid?

      aggregate_failures do
        expect(receipt.country_region).to eq('JP')
        expect(receipt.errors[:country_region]).to be_present
      end
    end
  end

  describe 'currency_code normalization' do
    it 'currency_code はuppercaseに正規化する' do
      receipt = build(:receipt, currency_code: ' jpy ')

      receipt.valid?

      expect(receipt.currency_code).to eq('JPY')
    end

    it 'currency_code は3文字の英字だけを許可する' do
      receipt = build(:receipt, currency_code: 'JP')

      expect(receipt).not_to be_valid
      expect(receipt.errors[:currency_code]).to be_present
    end
  end

  describe 'store_address_components normalization' do
    it 'store_address_components は文字列キーへ正規化する' do
      receipt = build(:receipt, store_address_components: { state: '東京都', streetAddress: '1-2-3' })

      receipt.valid?

      expect(receipt.store_address_components).to eq(
        'state' => '東京都',
        'streetAddress' => '1-2-3'
      )
    end

    it 'store_address_components はHashだけを許可する' do
      receipt = build(:receipt, store_address_components: [ '東京都' ])

      expect(receipt).not_to be_valid
      expect(receipt.errors[:store_address_components]).to be_present
    end
  end

  describe 'receipt item count limit' do
    def build_items(receipt, count)
      count.times do |index|
        receipt.receipt_items.build(
          raw_text: "商品#{index}",
          confirmed_name: "商品#{index}",
          price: 100,
          quantity: 1,
          line_total: 100,
          position_index: index + 1
        )
      end
    end

    it 'default上限までは有効にする' do
      receipt = build(:receipt)
      build_items(receipt, 100)

      expect(receipt).to be_valid
    end

    it 'default上限を超える明細を拒否する' do
      receipt = build(:receipt)
      build_items(receipt, 101)

      aggregate_failures do
        expect(receipt).not_to be_valid
        expect(receipt.errors.of_kind?(:receipt_items, :too_many)).to be(true)
      end
    end

    it 'user overrideで上限を引き上げられる' do
      user = create(:user)
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 150 })
      receipt = build(:receipt, user: user)
      build_items(receipt, 150)

      expect(receipt).to be_valid
    end

    it '削除予定の明細は件数に含めない' do
      user = create(:user)
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 2 })
      receipt = create(:receipt, user: user)
      existing = receipt.receipt_items.create!(confirmed_name: '既存', price: 100, quantity: 1, line_total: 100)

      receipt.assign_attributes(
        receipt_items_attributes: {
          '0' => { id: existing.id, _destroy: '1' },
          '1' => { confirmed_name: '新規1', price: 100, quantity: 1, line_total: 100 },
          '2' => { confirmed_name: '新規2', price: 100, quantity: 1, line_total: 100 }
        }
      )

      expect(receipt).to be_valid
    end
  end

  describe 'receipt structural child count limits' do
    it '調整行は設定上限を超えると無効にする' do
      create(:system_setting, key: 'limits.receipt_adjustments_per_receipt', value: SystemSettings.stored_value(1))
      receipt = build(:receipt)
      2.times do |index|
        receipt.receipt_adjustments.build(
          kind: 'coupon',
          sign: 'discount',
          source: 'manual',
          amount: 100,
          position_index: index
        )
      end

      aggregate_failures do
        expect(receipt).not_to be_valid
        expect(receipt.errors.of_kind?(:receipt_adjustments, :too_many)).to be(true)
      end
    end

    it '支払い行は設定上限を超えると無効にする' do
      create(:system_setting, key: 'limits.receipt_payments_per_receipt', value: SystemSettings.stored_value(1))
      receipt = build(:receipt)
      receipt.receipt_payments.build(method: 'Cash', amount: 100)
      receipt.receipt_payments.build(method: 'CreditCard', amount: 200)

      aggregate_failures do
        expect(receipt).not_to be_valid
        expect(receipt.errors.of_kind?(:receipt_payments, :too_many)).to be(true)
      end
    end

    it '税内訳は設定上限を超えると無効にする' do
      create(:system_setting, key: 'limits.receipt_tax_details_per_receipt', value: SystemSettings.stored_value(1))
      receipt = build(:receipt)
      receipt.receipt_tax_details.build(description: '10%対象', rate: 0.1, amount: 10, net_amount: 100)
      receipt.receipt_tax_details.build(description: '8%対象', rate: 0.08, amount: 8, net_amount: 100)

      aggregate_failures do
        expect(receipt).not_to be_valid
        expect(receipt.errors.of_kind?(:receipt_tax_details, :too_many)).to be(true)
      end
    end

    it '削除予定の構造子要素は件数に含めない' do
      create(:system_setting, key: 'limits.receipt_adjustments_per_receipt', value: SystemSettings.stored_value(1))
      receipt = create(:receipt)
      adjustment = create(:receipt_adjustment, receipt: receipt)

      receipt.assign_attributes(
        receipt_adjustments_attributes: {
          '0' => { id: adjustment.id, _destroy: '1' },
          '1' => { kind: 'coupon', sign: 'discount', source: 'manual', amount: 200 }
        }
      )

      expect(receipt).to be_valid
    end
  end

  describe 'query indexes' do
    it 'receipts index / KPI / status count 用の複合indexを持つ' do
      indexes = ActiveRecord::Base.connection.indexes(:receipts)

      aggregate_failures do
        expect(indexes).to include(have_attributes(columns: %w[public_id], unique: true))
        expect(indexes).to include(have_attributes(columns: %w[user_id display_id], unique: true))
        expect(indexes).to include(have_attributes(columns: %w[user_id created_at]))
        expect(indexes).to include(have_attributes(columns: %w[user_id status]))
        expect(indexes).to include(have_attributes(columns: %w[user_id status purchased_at]))
      end
    end
  end

  describe '#processing_error_user_message' do
    it '処理失敗toastの文言を処理失敗トーンへ寄せる' do
      expect(I18n.t('flash.receipts.analysis_failed')).to eq("処理に失敗しました。\n内容を確認してください。")
    end

    it '処理失敗の永続通知本文を処理失敗トーンへ寄せる' do
      expect(I18n.t('notifications.receipts.failed.body', subject: 'テストレシート')).to eq('テストレシートの処理に失敗しました。')
    end

    it 'AI一時停止はAI失敗ではなく一時停止中として表示する' do
      receipt = build_stubbed(:receipt, :failed, processing_error_code: 'ai_unavailable')

      expect(receipt.processing_error_user_message).to eq('AI補完は一時停止中です。OCR結果を確認・修正してください。')
    end

    it 'AI共通エラーはOCR結果の確認・修正文言へ寄せる' do
      receipt = build_stubbed(:receipt, :failed, processing_error_code: 'analysis_missing_keys')

      aggregate_failures do
        expect(receipt.processing_error_user_message).to eq('AI補完に失敗しました。OCR結果を確認・修正してください。')
        expect(receipt.processing_error_user_message).not_to include(
          'OCR結果が不正です',
          'OCRが失敗しています',
          'OCR結果のlinesが不足しています',
          'OCR結果のcandidatesが不足しています'
        )
      end
    end

    it 'AI provider失敗もAI共通エラー文言へ寄せる' do
      aggregate_failures do
        expect(build_stubbed(:receipt, :review_needed, processing_error_code: 'ai_primary_failed').processing_error_user_message)
          .to eq('AI補完に失敗しました。OCR結果を確認・修正してください。')
        expect(build_stubbed(:receipt, :review_needed, processing_error_code: 'ai_fallback_failed').processing_error_user_message)
          .to eq('AI補完に失敗しました。OCR結果を確認・修正してください。')
      end
    end

    it 'OCR外部サービスの細分エラーはprovider詳細を出さず一般文言へ丸める' do
      %w[
        external_service_quota_exceeded
        external_service_rate_limited
        external_service_auth_error
        external_service_unavailable
      ].each do |error_code|
        message = build_stubbed(:receipt, :failed, processing_error_code: error_code).processing_error_user_message

        aggregate_failures(error_code) do
          expect(message).to eq('OCRサービスを現在利用できません。時間をおいて再試行するか、手動入力で続行してください。')
          expect(message).not_to include(error_code, 'Azure', 'request_id', 'policy-id')
        end
      end
    end

    it 'AI外部サービスの細分エラーはprovider詳細を出さず一般文言へ丸める' do
      %w[
        ai_quota_exceeded
        ai_rate_limited
        ai_auth_error
        ai_config_error
        ai_timeout
        ai_invalid_request
        ai_invalid_response
        ai_api_error
      ].each do |error_code|
        message = build_stubbed(:receipt, :failed, processing_error_code: error_code).processing_error_user_message

        aggregate_failures(error_code) do
          expect(message).to eq('AI補完を現在利用できません。OCR結果を確認・修正してください。')
          expect(message).not_to include(error_code, 'OpenAI', 'request_id', 'provider')
        end
      end
    end

    it '文字読み取り不可とレシート認識不可を別文言にする' do
      no_text_receipt = build_stubbed(:receipt, :failed, processing_error_code: 'no_text_detected')
      not_detected_receipt = build_stubbed(:receipt, :failed, processing_error_code: 'receipt_not_detected')
      ai_not_receipt = build_stubbed(:receipt, :failed, processing_error_code: 'ai_not_receipt')

      aggregate_failures do
        expect(no_text_receipt.processing_error_user_message).to eq('画像から文字を読み取れませんでした。明るさやピントを確認して、別の画像でお試しください。')
        expect(not_detected_receipt.processing_error_user_message).to eq('レシートを認識できませんでした。レシート全体が写っている画像でお試しください。')
        expect(ai_not_receipt.processing_error_user_message).to eq(not_detected_receipt.processing_error_user_message)
      end
    end

    it '海外レシートは日本レシートのみ対応文言にする' do
      receipt = build_stubbed(:receipt, :failed, processing_error_code: 'unsupported_country')

      expect(receipt.processing_error_user_message).to eq('現在は日本のレシートのみ対応しています。日本国内のレシート画像でお試しください。')
    end

    it 'AI not receiptの不確実ケースは確認系文言にする' do
      receipt = build_stubbed(:receipt, :review_needed, processing_error_code: 'ai_not_receipt_uncertain')

      expect(receipt.processing_error_user_message).to eq('レシート判定に迷いがあります。OCR結果を確認してください。')
    end

    it '英語localeでも処理失敗文言をcodeから表示できる' do
      I18n.with_locale(:en) do
        aggregate_failures do
          expect(build_stubbed(:receipt, :failed, processing_error_code: 'analysis_missing_keys').processing_error_user_message)
            .to eq('AI assistance failed. Please review and edit the OCR results.')
          expect(build_stubbed(:receipt, :failed, processing_error_code: 'image_missing').processing_error_user_message)
            .to eq('The image could not be loaded. Try another image or continue by entering the details manually.')
          expect(build_stubbed(:receipt, :failed, processing_error_code: 'ai_api_error').processing_error_user_message)
            .to eq('AI assistance is currently unavailable. Please review and edit the OCR results.')
        end
      end
    end
  end

  describe 'broadcasts' do
    let(:user) { create(:user) }

    it 'processing receipt作成時だけprepend callbackを実行する' do
      expect_any_instance_of(described_class).to receive(:broadcast_receipt_card_prepend).once

      create(:receipt, :processing, :with_image, user: user)
      create(:receipt, :completed, user: user)
    end

    it 'processing作成時にreceipts-list-gridへカードをprependする' do
      receipt = build_stubbed(:receipt, :processing, user: user)

      expect(receipt).to receive(:broadcast_prepend_later_to).with(
        [ user, :receipts, :index_first_page ],
        target: "receipts-list-grid",
        partial: "shared/receipts/receipt_card",
        locals: { receipt: receipt }
      )
      expect(receipt).to receive(:broadcast_remove_to).with(
        [ user, :receipts, :index_first_page ],
        target: "receipts-empty-state"
      )

      receipt.send(:broadcast_receipt_card_prepend)
    end

    it 'create時にもsummary cardsをreplaceするcallbackを持つ' do
      create_callback_filters = described_class.__send__(:get_callbacks, :commit).select do |callback|
        callback.kind == :after
      end.map(&:filter)

      expect(create_callback_filters).to include(:broadcast_created_summary_cards_update)
    end

    it 'summary broadcast localsにfailed_countを含める' do
      receipt = build_stubbed(:receipt, user: user)
      summary = described_class.summary_for(user)

      expect(receipt).to receive(:broadcast_replace_later_to).with(
        [ user, :receipts ],
        target: "receipts_summary",
        partial: "shared/receipts/summary_cards",
        locals: hash_including(
          failed_count: summary[:failed_count],
          animate_on_connect: true
        )
      )

      receipt.send(:broadcast_summary_cards_update)
    end

    it 'status更新時の既存broadcastを維持する' do
      receipt = create(:receipt, :processing, :with_image, user: user)

      expect(receipt).to receive(:broadcast_receipt_card_update).and_call_original
      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original
      expect(receipt).to receive(:broadcast_processing_flash).and_call_original

      receipt.update!(status: "completed")
    end

    it '通知OFFでもcard / summary broadcastは維持し、processing flashだけ呼ばない' do
      user.update!(push_notification_enabled: false)
      receipt = create(:receipt, :processing, :with_image, user: user)

      expect(receipt).to receive(:broadcast_receipt_card_update).and_call_original
      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original
      expect(receipt).not_to receive(:broadcast_processing_flash)

      receipt.update!(status: "completed")
    end

    it 'processingからcompletedになった時に永続通知を作成する' do
      receipt = create(:receipt, :processing, :with_image, user: user, store_name: '完了ストア')

      expect {
        receipt.update!(status: 'completed')
      }.to change(user.notifications, :count).by(1)

      notification = user.notifications.last

      aggregate_failures do
        expect(notification.kind).to eq('receipt_completed')
        expect(notification.notifiable).to eq(receipt)
        expect(notification.action_path).to eq("/receipts/#{receipt.public_id}")
        expect(notification.title).to include('完了')
      end
    end

    it 'destroy時に紐づく永続通知も削除する' do
      receipt = create(:receipt, :completed, user: user)
      notification = create(
        :notification,
        user: user,
        notifiable: receipt,
        action_path: "/receipts/#{receipt.public_id}"
      )

      expect {
        receipt.destroy!
      }.to change(Notification, :count).by(-1)

      expect(Notification.exists?(notification.id)).to be(false)
    end

    it '通知OFFでも永続Notificationは作成する' do
      user.update!(push_notification_enabled: false)
      receipt = create(:receipt, :processing, :with_image, user: user, store_name: '通知OFFストア')

      expect {
        receipt.update!(status: 'completed')
      }.to change(user.notifications, :count).by(1)

      expect(user.notifications.last.kind).to eq('receipt_completed')
    end

    it 'uploadedからreview_neededになった時に永続通知を作成する' do
      receipt = create(:receipt, status: 'uploaded', user: user)

      expect {
        receipt.update!(status: 'review_needed')
      }.to change(user.notifications, :count).by(1)

      expect(user.notifications.last.kind).to eq('receipt_review_needed')
    end

    it 'fallback error_codeがあってもreview_needed通知はstatusベースの本文にする' do
      receipt = create(:receipt, :processing, :with_image, user: user, store_name: '確認ストア')

      expect {
        receipt.update!(status: 'review_needed', processing_error_code: 'ai_primary_failed')
      }.to change(user.notifications, :count).by(1)

      notification = user.notifications.last

      aggregate_failures do
        expect(notification.kind).to eq('receipt_review_needed')
        expect(notification.body).to eq(I18n.t('notifications.receipts.review_needed.body', subject: '確認ストア'))
        expect(notification.body).not_to include('AI補完に失敗')
      end
    end

    it 'processingからfailedになった時に永続通知を作成する' do
      receipt = create(:receipt, :processing, :with_image, user: user)

      expect {
        receipt.update!(status: 'failed', processing_error_code: 'ocr_api_error')
      }.to change(user.notifications, :count).by(1)

      notification = user.notifications.last

      aggregate_failures do
        expect(notification.kind).to eq('receipt_failed')
        expect(notification.body).to be_present
      end
    end

    it '同じreceipt + same kind の永続通知は重複作成しない' do
      receipt = create(:receipt, :processing, :with_image, user: user)
      existing_notification = create(
        :notification,
        user: user,
        kind: 'receipt_failed',
        notifiable: receipt,
        action_path: "/receipts/#{receipt.public_id}",
        metadata: { receipt_id: receipt.id, status: 'failed' }
      )

      expect {
        receipt.update!(status: 'failed', processing_error_code: 'ocr_api_error')
      }.not_to change(user.notifications, :count)

      expect(user.notifications.where(kind: 'receipt_failed', notifiable: receipt)).to contain_exactly(existing_notification)
    end

    it 'processing -> failed を複数回試しても receipt_failed 通知は1件に抑える' do
      receipt = create(:receipt, :processing, :with_image, user: user)

      receipt.update!(status: 'failed', processing_error_code: 'ocr_api_error')
      receipt.update!(status: 'processing')

      expect {
        receipt.update!(status: 'failed', processing_error_code: 'ocr_timeout')
      }.not_to change { user.notifications.where(kind: 'receipt_failed', notifiable: receipt).count }

      expect(user.notifications.where(kind: 'receipt_failed', notifiable: receipt).count).to eq(1)
    end

    it 'review_needed と failed は別kindとして共存できる' do
      receipt = create(:receipt, :processing, :with_image, user: user)

      receipt.update!(status: 'review_needed')
      receipt.update!(status: 'processing')

      expect {
        receipt.update!(status: 'failed', processing_error_code: 'ocr_api_error')
      }.to change(user.notifications, :count).by(1)

      expect(user.notifications.where(notifiable: receipt).pluck(:kind)).to contain_exactly(
        'receipt_review_needed',
        'receipt_failed'
      )
    end

    it 'failedからcompletedに手動復旧しても永続通知を作成しない' do
      receipt = create(:receipt, :failed, user: user)

      expect {
        receipt.update!(status: 'completed', processing_error_code: nil)
      }.not_to change(user.notifications, :count)
    end

    it 'status変更なしでは永続通知を作成しない' do
      receipt = create(:receipt, :completed, user: user)

      expect {
        receipt.update!(store_name: '更新後ストア')
      }.not_to change(user.notifications, :count)
    end

    it 'completed/review_needed/failed のprocessing flashをappend専用toastへbroadcastする' do
      cases = [
        {
          status: "completed",
          processing_error_code: nil,
          flash_type: :notice,
          message: I18n.t("flash.receipts.analysis_completed")
        },
        {
          status: "review_needed",
          processing_error_code: nil,
          flash_type: :caution,
          message: I18n.t("flash.receipts.analysis_review_needed")
        },
        {
          status: "failed",
          processing_error_code: "ocr_api_error",
          flash_type: :alert,
          message: I18n.t("receipts.processing_errors.ocr_error")
        }
      ]

      cases.each do |entry|
        receipt = build_stubbed(
          :receipt,
          user: user,
          status: entry[:status],
          processing_error_code: entry[:processing_error_code]
        )

        expect(receipt).to receive(:broadcast_append_later_to).with(
          [ user, :receipts ],
          target: "toast-stream",
          partial: "shared/ui/feedback/toast_notice",
          locals: {
            notice_type: entry[:flash_type],
            message: entry[:message]
          }
        )

        receipt.send(:broadcast_processing_flash)
      end
    end

    it 'processing flashには保存済み内部messageを使わない' do
      receipt = build_stubbed(
        :receipt,
        user: user,
        status: "failed",
        processing_error_code: "analysis_missing_keys",
        processing_error_message: "OCR結果が不正です"
      )

      expect(receipt).to receive(:broadcast_append_later_to).with(
        [ user, :receipts ],
        target: "toast-stream",
        partial: "shared/ui/feedback/toast_notice",
        locals: {
          notice_type: :alert,
          message: I18n.t("receipts.processing_errors.ai_error")
        }
      )

      receipt.send(:broadcast_processing_flash)
    end

    it '通知OFFではprocessing flashをbroadcastしない' do
      user.update!(push_notification_enabled: false)
      receipt = build_stubbed(:receipt, user: user, status: "completed")

      expect(receipt).not_to receive(:broadcast_append_later_to)

      receipt.send(:broadcast_processing_flash)
    end

    it 'total_amount更新時にsummary cardsをreplaceする' do
      receipt = create(:receipt, :completed, user: user)

      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original

      receipt.update!(total_amount: 2_000)
    end

    it 'purchased_at更新時にsummary cardsをreplaceする' do
      receipt = create(:receipt, :completed, user: user)

      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original

      receipt.update!(purchased_at: 1.month.ago)
    end

    it 'destroy時にsummary cardsをreplaceする' do
      receipt = create(:receipt, :completed, user: user)

      expect(receipt).to receive(:broadcast_summary_cards_update).and_call_original

      receipt.destroy!
    end
  end
end
