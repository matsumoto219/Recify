require 'rails_helper'
require 'zlib'

RSpec.describe Receipt, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  def png_bytes(width:, height:)
    chunk = lambda do |type, data|
      [ data.bytesize ].pack('N') + type + data + [ Zlib.crc32(type + data) ].pack('N')
    end
    header = [ width, height, 8, 2, 0, 0, 0 ].pack('NNCCCCC')
    row = "\x00".b + ("\xFF\xFF\xFF".b * width)
    compressed = Zlib::Deflate.deflate(row * height)

    "\x89PNG\r\n\x1A\n".b +
      chunk.call('IHDR'.b, header) +
      chunk.call('IDAT'.b, compressed) +
      chunk.call('IEND'.b, ''.b)
  end

  def attach_png(receipt, width:, height:)
    receipt.image.attach(
      io: StringIO.new(png_bytes(width: width, height: height)),
      filename: "receipt-#{width}x#{height}.png",
      content_type: 'image/png'
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

      scope = user.receipts.search('コーヒー')
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
          quantity_unit: "個",
          price: total_amount,
          line_total: total_amount,
          position_index: 1
        )
      end

      receipt
    end

    it 'subquery用途のmatching idsには既存orderを持ち込まない' do
      sql = described_class.order(created_at: :desc).search('コーヒー').to_sql

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

      expect(user.receipts.search('サンプルコンビニ 1000')).to contain_exactly(target)
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
        expect(user.receipts.search('<=1000')).to contain_exactly(low, exact)
        expect(user.receipts.search('>=1000')).to contain_exactly(exact, high)
        expect(user.receipts.search('amount<=1000')).to contain_exactly(low, exact)
        expect(user.receipts.search('total>=1000')).to contain_exactly(exact, high)
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

      expect(user.receipts.search('牛乳 <=300')).to contain_exactly(target)
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
        expect(user.receipts.search('2026-01-10')).to contain_exactly(january_10)
        expect(user.receipts.search('date>=2026-01-15')).to contain_exactly(january_20, february)
        expect(user.receipts.search('date<=2026-01-10')).to contain_exactly(january_10)
        expect(user.receipts.search('date:2026-01-01..2026-01-31')).to contain_exactly(january_10, january_20)
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
          expect { user.receipts.search(query).load }.not_to raise_error
          expect(user.receipts.search(query)).to be_empty
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
        expect(user.receipts.search('date>=2026-01-01 date<=2026-01-31')).to contain_exactly(january_10, january_20)
        expect(user.receipts.search('date>=2026-01-15 date>=2026-02-01')).to contain_exactly(february)
        expect(user.receipts.search('date>=2026-02-01 date<=2026-01-31')).to be_empty
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

      expect(user.receipts.search('サンプルコンビニ <=1000 date>=2026-01-01')).to contain_exactly(target)
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

    it 'country_region はuppercaseに正規化し、2文字コードを3文字へ変換しない' do
      receipt = build(:receipt, country_region: ' jp ')

      receipt.valid?

      expect(receipt.country_region).to eq('JP')
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
      expect(I18n.t('flash.receipts.analysis_failed')).to eq('処理に失敗しました。内容を確認してください')
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

      expect(receipt.processing_error_user_message).to eq('AI補完に失敗しました。OCR結果を確認・修正してください。')
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
