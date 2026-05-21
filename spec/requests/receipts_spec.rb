require 'rails_helper'

RSpec.describe 'Receipts', type: :request do
  let(:user) { create(:user) }
  let(:image_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:uploaded_image) do
    Rack::Test::UploadedFile.new(image_path, 'image/jpeg')
  end

  def uploaded_receipt_fixture(filename = 'receipt_sample.jpg', content_type = 'image/jpeg')
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files', filename), content_type)
  end

  def upload_ocr_result(overrides = {})
    {
      success: true,
      raw_text: "統合テストストア\nコーヒー 180\nサンド 550 x2\n合計 1280\nMaster",
      lines: [
        '統合テストストア',
        'コーヒー 180',
        'サンド 550 x2',
        '合計 1280',
        'Master'
      ],
      candidates: {
        store_name: '統合テストストア',
        total_amount: 1280,
        subtotal_amount: 1164,
        tax_amount: 116,
        payment_method_text: 'Master',
        country_region: 'JP',
        items: [
          {
            raw_text: 'コーヒー',
            price: 180,
            quantity: 1,
            quantity_unit: '杯',
            line_total: 180,
            tax_rate: 10,
            confidence: 0.98
          },
          {
            raw_text: 'サンド',
            price: 550,
            quantity: 2,
            quantity_unit: '個',
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
      }
    }.deep_merge(overrides)
  end

  def failed_ai_result(error_code = 'analysis_missing_keys')
    {
      success: false,
      error_code: error_code,
      receipt_attributes: {},
      receipt_items_attributes: []
    }
  end

  before do
    sign_in user
    allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_return({ error_category: 'ocr_error' })
  end

  describe 'GET /receipts' do
    let!(:my_receipt) do
      create(:receipt, user: user, store_name: '自分のレシート', total_amount: 1000, payment_method: 'cash', status: 'completed')
    end
    let!(:other_receipt) do
      other_user = create(:user, email: 'index_other@example.com')
      create(:receipt, user: other_user, store_name: '他人のレシート', total_amount: 999, payment_method: 'cash', status: 'completed')
    end

    it '一覧を取得できる' do
      get receipts_path

      expect(response).to have_http_status(:success)
    end

    it '自分のレシートだけが表示される' do
      get receipts_path

      aggregate_failures do
        expect(response.body).to include('自分のレシート')
        expect(response.body).not_to include('他人のレシート')
      end
    end

    it 'リアルタイム追加用のreceipts-list-gridを持つ' do
      get receipts_path

      document = Nokogiri::HTML(response.body)
      results = document.at_css('#receipts-results')

      aggregate_failures do
        expect(results).to be_present
        expect(results.at_css('#receipts-list')).to be_present
        expect(results.at_css('#receipts-list-grid')).to be_present
        expect(results.at_css('#receipts-empty-state')).to be_nil
      end
    end

    it '非検索の1ページ目ではcreate prepend専用streamも購読する' do
      get receipts_path

      document = Nokogiri::HTML(response.body)
      results = document.at_css('#receipts-results')

      aggregate_failures do
        expect(document.css('turbo-cable-stream-source').size).to eq(3)
        expect(results.css('turbo-cable-stream-source').size).to eq(1)
      end
    end

    it '検索結果ではcreate prepend専用streamを購読しない' do
      get receipts_path(q: my_receipt.store_name)

      document = Nokogiri::HTML(response.body)

      expect(document.css('turbo-cable-stream-source').size).to eq(2)
    end

    it 'q parameter を検索フォームの値として保持する' do
      get receipts_path(q: my_receipt.store_name)

      document = Nokogiri::HTML(response.body)

      expect(document.at_css('input[name="q"]')['value']).to eq(my_receipt.store_name)
    end

    it 'realtime search error文言をdata属性で渡す' do
      get receipts_path

      document = Nokogiri::HTML(response.body)
      search_controller = document.at_css('[data-controller~="search"]')

      aggregate_failures do
        expect(search_controller['data-search-error-title-value']).to eq(I18n.t('search.realtime.error_title'))
        expect(search_controller['data-search-error-message-value']).to eq(I18n.t('search.realtime.error_message'))
        expect(search_controller['data-search-error-close-label-value']).to eq(I18n.t('search.realtime.close_label'))
      end
    end

    it '一覧dashboard/header/nav文言とsummary controller用文言をlocale経由で描画する' do
      get receipts_path

      document = Nokogiri::HTML(response.body)
      summary = document.at_css('#receipts_summary')
      summary_cards = summary.xpath('./section')
      total_count_card = summary_cards.find { |card| card.text.include?(I18n.t('dashboard.summary.total_count.title')) }
      header = document.at_css('#dashboard-header')
      page_header_action = document.at_css("#receipts-page-header a[href='#{select_input_method_receipts_path}']").parent

      aggregate_failures do
        expect(document.at_css('#receipts-page-header').text).to include(I18n.t('receipts.index.title'))
        expect(document.at_css('#receipts-page-header').text).to include(I18n.t('dashboard.index.default_subtitle'))
        expect(document.at_css('#desktop-sidebar').text).to include(I18n.t('dashboard.nav.receipts'))
        expect(document.at_css('#desktop-sidebar').text).to include(I18n.t('dashboard.nav.new_receipt'))
        expect(document.at_css('#mobile-bottom-nav').text).to include(I18n.t('dashboard.nav.mobile_receipts'))
        expect(header.at_css('input[name="q"]')['placeholder']).to eq(I18n.t('dashboard.search.placeholder'))
        expect(header.at_css('[data-search-target="toggle"]')['aria-label']).to eq(I18n.t('dashboard.header.search_label'))
        expect(header.at_css('[data-notification-dropdown-target="button"]')['aria-label']).to eq(I18n.t('dashboard.header.notifications_label'))
        expect(summary.text).to include(I18n.t('dashboard.summary.total_count.title'))
        expect(summary.text).to include(I18n.t('dashboard.summary.amount.current_month_title'))
        expect(summary.text).to include(I18n.t('dashboard.summary.processing.title'))
        expect(summary.text).to include(I18n.t('dashboard.summary.review_needed.title'))
        expect(summary.text).to include(I18n.t('dashboard.summary.failed.title'))
        expect(summary['class'].split).to include('grid')
        expect(summary['class'].split).not_to include('hidden')
        expect(summary['class']).to include('md:grid-cols-4')
        expect(summary['class']).to include('xl:grid-cols-5')
        expect(total_count_card['class']).to include('hidden')
        expect(total_count_card['class']).to include('xl:block')
        expect(page_header_action['class'].split).to include('flex')
        expect(page_header_action['class'].split).not_to include('hidden')
        expect(summary['data-receipt-summary-monthly-label-value']).to eq(I18n.t('dashboard.summary.amount.current_month_title'))
        expect(summary['data-receipt-summary-overall-label-value']).to eq(I18n.t('dashboard.summary.amount.overall_title'))
        expect(summary['data-receipt-summary-change-label-value']).to eq(I18n.t('dashboard.summary.amount.monthly_change_prefix'))
        expect(summary['data-receipt-summary-count-suffix-value']).to eq(I18n.t('dashboard.summary.count_suffix'))
      end
    end

    it 'スマホ検索結果ではsummaryとページヘッダー登録ボタンだけを非表示にする' do
      get receipts_path(q: my_receipt.store_name)

      document = Nokogiri::HTML(response.body)
      summary = document.at_css('#receipts_summary')
      page_header_action = document.at_css("#receipts-page-header a[href='#{select_input_method_receipts_path}']").parent
      mobile_bottom_nav_action = document.at_css("#mobile-bottom-nav a[href='#{select_input_method_receipts_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(summary['class'].split).to include('hidden')
        expect(summary['class'].split).to include('md:grid')
        expect(page_header_action['class'].split).to include('hidden')
        expect(page_header_action['class'].split).to include('md:block')
        expect(mobile_bottom_nav_action).to be_present
        expect(mobile_bottom_nav_action.text).to include(I18n.t('dashboard.nav.mobile_new_receipt'))
      end
    end

    it 'sidebarに実ストレージ使用量を表示する' do
      user.update!(storage_limit_bytes: 10.megabytes)
      my_receipt.image.attach(
        io: StringIO.new('a' * 1.megabyte),
        filename: 'receipt-storage.jpg',
        content_type: 'image/jpeg'
      )

      get receipts_path

      document = Nokogiri::HTML(response.body)
      meter = document.at_css('#desktop-sidebar [data-storage-usage-meter]')

      aggregate_failures do
        expect(meter).to be_present
        expect(meter.text).to include('1MB / 10MB')
      end
    end

    it 'sidebarのストレージ使用量0は単位なしで表示する' do
      user.update!(storage_limit_bytes: 1.gigabyte)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      meter = document.at_css('#desktop-sidebar [data-storage-usage-meter]')

      expect(meter.text).to include('0 / 1GB')
    end

    it 'receipt cardのfallback/action文言をlocale経由で描画する' do
      my_receipt.update_columns(store_name: nil, purchased_at: nil)
      processing_receipt = create(:receipt, :processing, :with_image, user: user, store_name: nil)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      completed_card = document.at_css("#receipt_#{my_receipt.id}")
      processing_card = document.at_css("#receipt_#{processing_receipt.id}")

      aggregate_failures do
        expect(completed_card.text).to include(I18n.t('receipt_cards.fallback.store_name'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.fallback.purchased_at'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.labels.total_amount'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.actions.show'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.actions.edit'))
        expect(processing_card.text).to include(I18n.t('receipt_cards.fallback.processing_store_name'))
        expect(processing_card.text).to include(I18n.t('receipt_cards.fallback.processing_description'))
      end
    end

    it 'receipt listのempty state文言をlocale経由で描画する' do
      user.receipts.destroy_all

      get receipts_path

      document = Nokogiri::HTML(response.body)
      empty_state = document.at_css('#receipts-empty-state')

      aggregate_failures 'default empty state' do
        expect(empty_state.text).to include(I18n.t('receipt_cards.empty.default.title'))
        expect(empty_state.text).to include(I18n.t('receipt_cards.empty.default.description'))
        expect(empty_state.text).to include(I18n.t('receipt_cards.empty.default.action'))
      end

      get receipts_path(q: '一致しない検索語')

      document = Nokogiri::HTML(response.body)
      empty_state = document.at_css('#receipts-empty-state')

      aggregate_failures 'search empty state' do
        expect(empty_state.text).to include(I18n.t('receipt_cards.empty.search.title'))
        expect(empty_state.text).to include(I18n.t('receipt_cards.empty.search.description_suffix'))
        expect(empty_state.text).to include(I18n.t('receipt_cards.empty.search.back_to_index'))
      end
    end

    it 'mobile search panel is rendered outside the glass header' do
      get receipts_path(q: my_receipt.store_name)

      document = Nokogiri::HTML(response.body)
      header = document.at_css('#dashboard-header')
      mobile_panel = document.at_css('#mobile-search-panel')

      aggregate_failures do
        expect(mobile_panel).to be_present
        expect(mobile_panel.ancestors).not_to include(header)
        expect(header.at_css('.search-panel-mobile')).to be_nil
        expect(mobile_panel.at_css('input[name="q"]')['value']).to eq(my_receipt.store_name)
      end
    end

    it '空のq parameterでは通常一覧を表示する' do
      get receipts_path(q: '')

      document = Nokogiri::HTML(response.body)
      summary = document.at_css('#receipts_summary')
      page_header_action = document.at_css("#receipts-page-header a[href='#{select_input_method_receipts_path}']").parent

      aggregate_failures do
        expect(document.at_css('#receipts-page-header').text).to include(I18n.t('receipts.index.title'))
        expect(document.at_css('#receipts-page-header').text).to include('1件')
        expect(summary['class'].split).to include('grid')
        expect(summary['class'].split).not_to include('hidden')
        expect(page_header_action['class'].split).to include('flex')
        expect(page_header_action['class'].split).not_to include('hidden')
        expect(document.css('turbo-cable-stream-source').size).to eq(3)
      end
    end

    it '検索結果が1ページ分の場合はresults内にpaginationを表示しない' do
      get receipts_path(q: my_receipt.store_name)

      document = Nokogiri::HTML(response.body)
      results = document.at_css('#receipts-results')

      aggregate_failures do
        expect(results.at_css('#receipts-list')).to be_present
        expect(results.at_css('nav[aria-label]')).to be_nil
      end
    end

    it '検索結果は作成日時の降順を維持しsummaryも検索scopeに合わせる' do
      older_receipt = create(
        :receipt,
        user: user,
        store_name: '検索順ストア',
        total_amount: 100,
        status: 'completed',
        created_at: 2.days.ago
      )
      newer_receipt = create(
        :receipt,
        user: user,
        store_name: '検索順ストア',
        total_amount: 200,
        status: 'review_needed',
        created_at: 1.hour.ago
      )
      create(
        :receipt,
        user: user,
        store_name: '検索順ストア',
        total_amount: 300,
        status: 'failed',
        created_at: 30.minutes.ago
      )

      get receipts_path(q: '検索順ストア')

      document = Nokogiri::HTML(response.body)
      card_ids = document.css('#receipts-list-grid > [id^="receipt_"]').map { |node| node['id'] }

      aggregate_failures do
        expect(card_ids.index("receipt_#{newer_receipt.id}")).to be < card_ids.index("receipt_#{older_receipt.id}")
        expect(document.at_css('#receipts-page-header').text).to include('3件')
        expect(document.at_css('#receipts_summary').text).to include('¥300')
      end
    end

    it '2ページ目ではcreate prepend専用streamを購読しない' do
      create_list(:receipt, 21, user: user, status: 'completed')

      get receipts_path(page: 2)

      document = Nokogiri::HTML(response.body)

      expect(document.css('turbo-cable-stream-source').size).to eq(2)
    end

    it 'pagination と End of Archive をリアルタイム検索更新用results内に含める' do
      create_list(:receipt, 21, user: user, status: 'completed')

      get receipts_path(page: 2)

      document = Nokogiri::HTML(response.body)
      results = document.at_css('#receipts-results')

      aggregate_failures do
        expect(results.at_css('#receipts-list')).to be_present
        expect(results.at_css('nav[aria-label="' + I18n.t('common.pagination.label') + '"]')).to be_present
        expect(results.text).to include(I18n.t('common.pagination.end_of_archive'))
      end
    end

    it '空状態をreceipts-empty-stateとしてgridから分離する' do
      user.receipts.destroy_all

      get receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(document.at_css('#receipts-list-grid')).to be_present
        expect(document.at_css('#receipts-empty-state')).to be_present
        expect(response.body).not_to include(I18n.t('common.pagination.end_of_archive'))
      end
    end

    it '検索0件ではEnd of Archiveを表示しない' do
      get receipts_path(q: '一致しない検索語')

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(document.at_css('#receipts-empty-state')).to be_present
        expect(response.body).not_to include(I18n.t('common.pagination.end_of_archive'))
      end
    end

    it '範囲外pageは最終ページへredirectする' do
      create_list(:receipt, 21, user: user, status: 'completed')

      get receipts_path(page: 999)

      expect(response).to redirect_to(receipts_path(page: 2))
    end

    it '検索結果の範囲外pageはqueryを維持して最終ページへredirectする' do
      get receipts_path(q: my_receipt.store_name, page: 2)

      expect(response).to redirect_to(receipts_path(q: my_receipt.store_name, page: 1))
    end

    it '検索0件では範囲外pageでもredirectしない' do
      get receipts_path(q: '一致しない検索語', page: 999)

      expect(response).to have_http_status(:success)
    end

    it 'page=0は1ページ目へredirectする' do
      get receipts_path(page: 0)

      expect(response).to redirect_to(receipts_path(page: 1))
    end

    it '不正なpageは1ページ目へredirectする' do
      get receipts_path(page: 'abc')

      expect(response).to redirect_to(receipts_path(page: 1))
    end

    it 'failed receipt の一覧カードから詳細/編集へ進める' do
      failed_receipt = create(:receipt, :failed, user: user)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{failed_receipt.id}")

      aggregate_failures do
        expect(card.at_css("a[href='#{receipt_path(failed_receipt, from: 'index')}']")).to be_present
        expect(card.at_css("a[href='#{edit_receipt_path(failed_receipt, from: 'index')}']")).to be_present
      end
    end

    it 'review_needed receipt の一覧カードから詳細/編集へ進める' do
      review_receipt = create(:receipt, :review_needed, user: user)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{review_receipt.id}")

      aggregate_failures do
        expect(card.at_css("a[href='#{receipt_path(review_receipt, from: 'index')}']")).to be_present
        expect(card.at_css("a[href='#{edit_receipt_path(review_receipt, from: 'index')}']")).to be_present
      end
    end

    it 'processing receipt の一覧カードは詳細/編集リンクを無効表示にする' do
      processing_receipt = create(:receipt, :processing, :with_image, user: user)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{processing_receipt.id}")

      aggregate_failures do
        expect(card.at_css("a[href='#{receipt_path(processing_receipt, from: 'index')}']")).to be_nil
        expect(card.at_css("a[href='#{edit_receipt_path(processing_receipt, from: 'index')}']")).to be_nil
        expect(card.text).to include(I18n.t('receipt_cards.actions.show'))
        expect(card.text).to include(I18n.t('receipt_cards.actions.edit'))
      end
    end

    it '処理失敗件数をsummary cardに表示する' do
      create(:receipt, :failed, user: user)
      create(:receipt, :failed, user: user)

      get receipts_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('dashboard.summary.failed.title'))
        expect(response.body).to include(I18n.t('dashboard.count', count: 2))
      end
    end

    it 'upload/processing flashの翻訳が存在する' do
      aggregate_failures do
        expect(I18n.t('flash.receipts.enqueued')).not_to match(/translation missing/i)
        expect(I18n.t('flash.receipts.processing')).not_to match(/translation missing/i)
      end
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get receipts_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'GET /receipts/new' do
    it '新規作成画面を取得できる' do
      get new_receipt_path

      expect(response).to have_http_status(:success)
    end

    it '主要文言をlocale経由で描画しJS用文言をform data属性へ渡す' do
      get new_receipt_path

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('receipts.form.titles.new'))
        expect(response.body).to include(I18n.t('receipts.form.sections.basic_info'))
        expect(response.body).to include(I18n.t('receipts.form.buttons.add_item'))
        expect(form['data-receipt-form-subtotal-label-value']).to eq(I18n.t('receipts.item_fields.subtotal'))
        expect(form['data-receipt-form-unset-label-value']).to eq(I18n.t('receipts.common.unset'))
        expect(form['data-receipt-form-multiple-tax-rates-label-value']).to eq(I18n.t('receipts.common.multiple_tax_rates'))
      end
    end

    it '手動登録モードでも画面を取得できる' do
      get new_receipt_path, params: { mode: 'manual' }

      expect(response).to have_http_status(:success)
    end

    it '新規明細はquantityを1で初期表示し金額と率は空欄にする' do
      get new_receipt_path

      document = Nokogiri::HTML(response.body)
      item_row = document.css('[data-receipt-form-target="itemRow"]').first
      template_html = document.at_css('template[data-receipt-form-target="template"]')&.inner_html.to_s
      template = Nokogiri::HTML.fragment(template_html)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(item_row.at_css('[data-receipt-form-target="quantityInput"]')['value']).to eq('1')
        expect(item_row.at_css('[data-receipt-form-target="priceInput"]')['value'].to_s).to eq('')
        expect(item_row.at_css('[data-receipt-form-target="discountRateInput"]')['value'].to_s).to eq('')
        expect(item_row.at_css('[data-receipt-form-target="taxRateInput"]')['value'].to_s).to eq('')
        expect(template.at_css('[data-receipt-form-target="quantityInput"]')['value']).to eq('1')
        expect(template.at_css('[data-receipt-form-target="priceInput"]')['value'].to_s).to eq('')
        expect(template.at_css('[data-receipt-form-target="discountRateInput"]')['value'].to_s).to eq('')
        expect(template.at_css('[data-receipt-form-target="taxRateInput"]')['value'].to_s).to eq('')
      end
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get new_receipt_path

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'GET /receipts/select_input_method' do
    it '登録方法選択画面の主要文言をlocale経由で描画する' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get select_input_method_receipts_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('receipts.select_input_method.title'))
        expect(response.body).to include(I18n.t('receipts.select_input_method.upload.title'))
        expect(response.body).to include(I18n.t('receipts.select_input_method.manual.title'))
      end
    end

    it 'OCR down時は画像アップロード導線をdisabled表示し手動入力は有効にする' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get select_input_method_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(document.at_css('[data-service-disabled="ocr"]')).to be_present
        expect(document.at_css('a[href="' + new_receipt_path + '"]')).to be_present
        expect(document.at_css('a[href="' + new_upload_receipts_path + '"]')).to be_nil
      end
    end

    it 'AI down時は画像アップロード導線をdisabledにせず注意を表示する' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'down' })

      get select_input_method_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('AI補完は一時停止中です。OCR結果をもとに確認・修正できます。')
        expect(document.at_css('a[href="' + new_upload_receipts_path + '"]')).to be_present
        expect(document.at_css('[data-service-disabled="ocr"]')).to be_nil
      end
    end
  end

  describe 'GET /receipts/new_upload' do
    it 'アップロード画面の主要文言をlocale経由で描画しJS用文言をdata属性へ渡す' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)
      upload_root = document.at_css('[data-controller~="receipt-upload"]')
      camera_input = document.at_css('input[type="file"][name="receipt[image]"]')
      library_input = document.at_css('input[type="file"][name="receipt[images][]"]')
      preview_controls = document.at_css('[data-receipt-upload-target="previewControls"]')
      preview_previous_button = document.at_css('[data-receipt-upload-target="previewPreviousButton"]')
      preview_next_button = document.at_css('[data-receipt-upload-target="previewNextButton"]')
      preview_counter = document.at_css('[data-receipt-upload-target="previewCounter"]')
      preview_current_file_name = document.at_css('[data-receipt-upload-target="previewCurrentFileName"]')
      expected_accept = %w[
        image/jpeg image/png image/bmp image/tiff image/heif image/heic
        .jpg .jpeg .png .bmp .tif .tiff .heif .heic
      ].join(',')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('receipts.new_upload.title'))
        expect(response.body).to include(I18n.t('receipts.new_upload.buttons.upload'))
        expect(upload_root['data-receipt-upload-invalid-image-message-value']).to eq(I18n.t('receipts.new_upload.js.invalid_image'))
        expect(upload_root['data-receipt-upload-empty-file-message-value']).to eq(I18n.t('receipts.new_upload.js.empty_file'))
        expect(upload_root['data-receipt-upload-storage-used-bytes-value']).to eq(user.storage_used_bytes.to_s)
        expect(upload_root['data-receipt-upload-storage-limit-bytes-value']).to eq(user.storage_limit_bytes.to_s)
        expect(upload_root['data-receipt-upload-quota-exceeded-message-value']).to eq(I18n.t('receipts.new_upload.js.quota_exceeded'))
        expect(upload_root['data-receipt-upload-max-file-count-value']).to eq(ReceiptBatchUploadService::MAX_FILES.to_s)
        expect(upload_root['data-receipt-upload-max-file-count-message-value']).to eq(I18n.t('receipts.new_upload.js.max_files', max: ReceiptBatchUploadService::MAX_FILES))
        expect(upload_root['data-receipt-upload-selected-files-message-value']).to eq(I18n.t('receipts.new_upload.js.selected_files'))
        expect(upload_root['data-receipt-upload-preview-counter-message-value']).to eq(I18n.t('receipts.new_upload.js.preview_counter'))
        expect(response.body).to include(I18n.t('receipts.new_upload.multiple_hint', max: ReceiptBatchUploadService::MAX_FILES))
        expect(camera_input['accept']).to eq(expected_accept)
        expect(camera_input['capture']).to eq('environment')
        expect(camera_input['multiple']).to be_nil
        expect(library_input['accept']).to eq(expected_accept)
        expect(library_input['multiple']).to eq('multiple')
        expect(preview_controls).to be_present
        expect(preview_controls['class']).to include('hidden')
        expect(preview_previous_button['type']).to eq('button')
        expect(preview_previous_button['aria-label']).to eq(I18n.t('receipts.new_upload.preview_previous_aria'))
        expect(preview_next_button['type']).to eq('button')
        expect(preview_next_button['aria-label']).to eq(I18n.t('receipts.new_upload.preview_next_aria'))
        expect(preview_counter['aria-live']).to eq('polite')
        expect(preview_current_file_name).to be_present
      end
    end

    it 'OCR down時は警告を表示しアップロード操作をdisabledにする' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(document.at_css('[data-receipt-upload-ocr-available-value="false"]')).to be_present
        expect(document.css('button[disabled]').map(&:text).join).to include('カメラを起動')
        expect(document.css('button[disabled]').map(&:text).join).to include('ファイルを選択')
        expect(document.css('button[disabled]').map(&:text).join).to include('アップロードして登録')
        expect(document.at_css('a[href="' + new_receipt_path + '"]')).to be_present
      end
    end

    it 'OCR degraded時はアップロード可能なまま注意を表示する' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'degraded' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('OCR解析に時間がかかる、または失敗する可能性があります。')
        expect(document.at_css('[data-receipt-upload-ocr-available-value="true"]')).to be_present
        expect(document.css('button[disabled]').map(&:text).join).not_to include('カメラを起動')
        expect(document.css('button[disabled]').map(&:text).join).not_to include('ファイルを選択')
      end
    end

    it 'AI down時はアップロード可能なまま注意を表示する' do
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'down' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('AI補完は一時停止中です。OCR結果をもとに確認・修正できます。')
        expect(document.at_css('[data-receipt-upload-ocr-available-value="true"]')).to be_present
        expect(document.css('button[disabled]').map(&:text).join).not_to include('カメラを起動')
        expect(document.css('button[disabled]').map(&:text).join).not_to include('ファイルを選択')
      end
    end
  end

  describe 'POST /receipts/upload' do
    it '単一camera uploadはreceipt[image]で従来通り成功する' do
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt).to be_processing
        expect(receipt.image).to be_attached
        expect(ReceiptAnalysisJob).to have_received(:perform_later).with(receipt.id)
      end
    end

    it 'library複数uploadで1ファイルごとにreceiptを作成し解析jobをenqueueする' do
      files = [
        uploaded_receipt_fixture,
        uploaded_receipt_fixture('single_tax_receipt.png', 'image/png'),
        uploaded_receipt_fixture('multiple_tax_receipt.png', 'image/png')
      ]
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.to change(Receipt, :count).by(3)

      created_receipts = Receipt.order(:id).last(3)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(created_receipts).to all(be_processing)
        expect(created_receipts).to all(satisfy { |receipt| receipt.image.attached? })
        created_receipts.each do |receipt|
          expect(ReceiptAnalysisJob).to have_received(:perform_later).with(receipt.id)
        end
      end
    end

    it '複数uploadが6件以上ならreceiptを作成せず解析jobもenqueueしない' do
      files = Array.new(6) { uploaded_receipt_fixture }
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.batch_upload.errors.too_many', max: ReceiptBatchUploadService::MAX_FILES))
        expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
      end
    end

    it '複数uploadにinvalid fileが混ざるとall-or-nothingでreceiptを作成しない' do
      invalid_file = Rack::Test::UploadedFile.new(
        Tempfile.create([ 'invalid-receipt-upload', '.txt' ]).tap { |file| file.write('dummy'); file.rewind }.path,
        'text/plain'
      )
      files = [
        uploaded_receipt_fixture,
        invalid_file
      ]
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.invalid_content_type'))
        expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
      end
    end

    it '複数uploadの合計サイズが残り容量を超えるとreceiptを作成せず解析jobもenqueueしない' do
      files = [
        uploaded_receipt_fixture,
        uploaded_receipt_fixture
      ]
      user.update!(storage_limit_bytes: files.first.size + 1)
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.batch_upload.errors.quota_exceeded'))
        expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
      end
    end

    it 'ストレージ上限超過時はreceiptを作成せず解析jobもenqueueしない' do
      user.update!(storage_limit_bytes: 1)
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.storage.quota_exceeded'))
        expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
      end
    end

    it 'Turbo requestでもストレージ上限guardはglobal error pageへ飛ばさずupload画面を維持する' do
      user.update!(storage_limit_bytes: 1)
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path,
             params: { receipt: { image: uploaded_image } },
             headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.new_upload.title'))
        expect(response.body).to include(I18n.t('flash.storage.quota_exceeded'))
        expect(response.body).not_to include('Error Code: 422')
        expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
      end
    end

    it 'OCR down時はreceiptを作成せず解析jobもenqueueしない' do
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(true)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
      end
    end

    it 'Turbo requestでもOCR down guardはglobal error pageへ飛ばさずupload画面を維持する' do
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(true)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path,
             params: { receipt: { image: uploaded_image } },
             headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.new_upload.title'))
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(response.body).not_to include('Error Code: 422')
        expect(ReceiptAnalysisJob).not_to have_received(:perform_later)
      end
    end

    it 'AI down時でもuploadは止めず解析jobをenqueueする' do
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'down' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(ReceiptAnalysisJob).to have_received(:perform_later).with(Receipt.order(:id).last.id)
      end
    end

    it '通知OFFならupload enqueueのredirect flashを表示しない' do
      user.update!(push_notification_enabled: false)
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptAnalysisJob).to receive(:perform_later)

      post upload_receipts_path, params: { receipt: { image: uploaded_image } }

      follow_redirect!
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#flash [data-controller~="notice-surface"]')).to be_nil
        expect(response.body).not_to include(I18n.t('flash.receipts.enqueued'))
      end
    end

    it 'upload後のjob実行でOCR失敗ならfailedになり一覧/詳細/編集で導線を表示する' do
      allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_call_original
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptOcrService).to receive(:call).and_return(
        success: false,
        error_code: 'ocr_timeout',
        lines: []
      )
      allow(ReceiptAiEnrichmentService).to receive(:call)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('processing')

      ReceiptAnalysisJob.perform_now(receipt.id)
      receipt.reload

      aggregate_failures 'failed receipt state' do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_timeout')
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      end

      get receipts_path
      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{receipt.id}")

      aggregate_failures 'index failed card' do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('dashboard.summary.failed.title'))
        expect(response.body).to include(I18n.t('dashboard.count', count: 1))
        expect(card).to be_present
        expect(card.text).to include('失敗')
        expect(card.at_css("a[href='#{receipt_path(receipt, from: 'index')}']")).to be_present
        expect(card.at_css("a[href='#{edit_receipt_path(receipt, from: 'index')}']")).to be_present
      end

      get receipt_path(receipt)

      aggregate_failures 'show failed guidance' do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include('OCR処理に失敗しました')
        expect(response.body).to include('編集して修正')
      end

      get edit_receipt_path(receipt)

      aggregate_failures 'edit failed guidance' do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include('OCR処理に失敗しました')
      end
    end

    it 'upload後のjob実行でOCR成功かつAI失敗ならOCR由来データを残してreview_needed導線を表示する' do
      allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_call_original
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:down?).with(:ai).and_return(false)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptOcrService).to receive(:call).and_return(upload_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('processing')

      ReceiptAnalysisJob.perform_now(receipt.id)
      receipt.reload

      aggregate_failures 'review_needed fallback state' do
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('analysis_missing_keys')
        expect(receipt.store_name).to eq('統合テストストア')
        expect(receipt.total_amount).to eq(1280)
        expect(receipt.receipt_items.count).to eq(2)
        expect(receipt.receipt_tax_details.count).to eq(1)
        expect(receipt.receipt_payments.count).to eq(1)
      end

      get receipts_path
      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{receipt.id}")

      aggregate_failures 'index review card' do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('要確認')
        expect(card).to be_present
        expect(card.at_css("a[href='#{receipt_path(receipt, from: 'index')}']")).to be_present
        expect(card.at_css("a[href='#{edit_receipt_path(receipt, from: 'index')}']")).to be_present
      end

      get receipt_path(receipt)

      aggregate_failures 'show fallback guidance' do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('処理に関する注意')
        expect(response.body).to include(I18n.t('receipts.processing_errors.ai_error'))
      end

      get edit_receipt_path(receipt)

      aggregate_failures 'edit fallback guidance' do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('処理に関する注意')
        expect(response.body).to include(I18n.t('receipts.processing_errors.ai_error'))
      end
    end

    it 'upload後のjob実行でAI downならAI呼び出しをskipしてOCR由来データを残す' do
      allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_call_original
      allow(ExternalServiceStatus).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServiceStatus).to receive(:down?).with(:ai).and_return(true)
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServiceStatus).to receive(:snapshot).with(:ai).and_return({ state: 'down' })
      allow(ReceiptOcrService).to receive(:call).and_return(upload_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('processing')

      ReceiptAnalysisJob.perform_now(receipt.id)
      receipt.reload

      aggregate_failures do
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to eq('ai_unavailable')
        expect(receipt.store_name).to eq('統合テストストア')
        expect(receipt.total_amount).to eq(1280)
        expect(receipt.receipt_items.count).to eq(2)
        expect(receipt.receipt_tax_details.count).to eq(1)
        expect(receipt.receipt_payments.count).to eq(1)
      end
    end
  end

  describe 'POST /receipts' do
    let(:valid_params) do
      {
        receipt: {
          store_name: 'テスト',
          total_amount: 1000,
          payment_method: 'cash',
          status: 'uploaded'
        }
      }
    end

    let(:invalid_params) do
      {
        receipt: {
          store_name: '',
          total_amount: nil,
          payment_method: 'cash',
          memo: 'x' * 1001,
          status: 'uploaded'
        }
      }
    end

    it 'レシートを作成できる' do
      expect do
        post receipts_path, params: valid_params
      end.to change(Receipt, :count).by(1)

      expect(response).to have_http_status(:redirect)
      expect(Receipt.order(:id).last.status).to eq('completed')
    end

    it 'redirect flashをnotice_surfaceのtoastとして描画する' do
      post receipts_path, params: valid_params

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      flash = document.at_css('#flash')
      notice_surface = flash.at_css('[data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(flash).to be_present
        expect(document.at_css('#toast-stream')).to be_present
        expect(notice_surface).to be_present
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('true')
        expect(notice_surface['data-notice-surface-max-visible-value']).to eq('3')
        expect(notice_surface.at_css('button[data-action="click->notice-surface#close"]')).to be_present
      end
    end

    it '通知OFFなら手動作成成功のredirect flashを表示しない' do
      user.update!(push_notification_enabled: false)

      post receipts_path, params: valid_params

      follow_redirect!
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#flash [data-controller~="notice-surface"]')).to be_nil
        expect(response.body).not_to include(I18n.t('flash.receipts.create'))
      end
    end

    it 'ログインユーザーに紐づいて作成される' do
      post receipts_path, params: valid_params

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(receipt.user).to eq(user)
        expect(receipt.store_name).to eq('テスト')
        expect(receipt.total_amount).to eq(1000)
      end
    end

    it '画像なし作成時にstatusが入る' do
      post receipts_path, params: valid_params

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('completed')
    end

    it '画像あり手動登録時もcompletedで保存され、解析は実行しない' do
      allow(ReceiptAnalysisService).to receive(:call)

      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '画像付きレシート',
            total_amount: 1500,
            payment_method: 'cash',
            image: uploaded_image
          }
        }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(ReceiptAnalysisService).not_to have_received(:call)
        expect(response).to redirect_to(receipts_path)
      end
    end

    it '画像あり手動登録時は解析失敗処理も実行しない' do
      allow(ReceiptAnalysisService).to receive(:call)

      post receipts_path, params: {
        receipt: {
          store_name: '解析しない画像付きレシート',
          total_amount: 1800,
          payment_method: 'cash',
          image: uploaded_image
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.status).to eq('completed')
        expect(ReceiptAnalysisService).not_to have_received(:call)
        expect(receipt.processing_error_code).to be_nil
      end
    end

    it '画像なし作成時は解析を実行しない' do
      allow(ReceiptAnalysisService).to receive(:call)

      post receipts_path, params: valid_params

      expect(ReceiptAnalysisService).not_to have_received(:call)
    end

    it '不正なパラメータでは作成できない' do
      expect do
        post receipts_path, params: invalid_params
      end.not_to change(Receipt, :count)

      expect([ 200, 422 ]).to include(response.status)
    end

    it '画像のみの手動登録失敗時はsigned_id errorにならず新規フォームに戻る' do
      expect do
        post receipts_path, params: {
          receipt: {
            image: uploaded_image
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.form.titles.new'))
        expect(document.at_css('#flash [data-controller~="notice-surface"]')).to be_present
        expect(document.at_css('[data-controller~="receipt-image-card"]')).to be_present
        expect(response.body).to include(I18n.t('shared.receipt_image_card.reselect_image'))
        expect(document.at_css('input[name="receipt[remove_image]"][value="1"]')).to be_nil
        expect(response.body).not_to include('Cannot get a signed_id')
      end
    end

    it 'flash.now alertの複数エラーをlist表示する' do
      post receipts_path, params: invalid_params

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')
      error_items = notice_surface.css('ul li')

      aggregate_failures do
        expect([ 200, 422 ]).to include(response.status)
        expect(notice_surface).to be_present
        expect(notice_surface['class']).to include('notice-surface-error')
        expect(notice_surface.text).to include(I18n.t('shared.notice_surface.titles.error'))
        expect(notice_surface.at_css('button[aria-label="' + I18n.t('shared.notice_surface.close_label') + '"]')).to be_present
        expect(error_items.size).to be >= 2
      end
    end

    it 'Turbo requestでもvalidation errorはglobal error pageへ飛ばさず入力フォームを維持する' do
      expect do
        post receipts_path,
             params: invalid_params,
             headers: { 'ACCEPT' => 'text/vnd.turbo-stream.html' }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.form.titles.new'))
        expect(response.body).not_to include('Error Code: 422')
        expect(notice_surface).to be_present
        expect(notice_surface['class']).to include('notice-surface-error')
      end
    end

    it '通知OFFでもvalidation errorは表示する' do
      user.update!(push_notification_enabled: false)

      post receipts_path, params: invalid_params

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface).to be_present
        expect(notice_surface['class']).to include('notice-surface-error')
        expect(notice_surface.text).to include(I18n.t('shared.notice_surface.titles.error'))
      end
    end

    it '明細あり作成時にsubtotal/tax/totalを再計算して保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '明細あり作成',
          payment_method: 'cash',
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 108,
              quantity: 2,
              quantity_unit: '個',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      item = receipt.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.subtotal_amount).to eq(197)
        expect(receipt.tax_amount).to eq(19)
        expect(receipt.total_amount).to eq(216)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(item.line_total).to eq(216)
      end
    end

    it '作成時のdiscount_rate入力をdiscount_amountへ変換しdiscount_rateも保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '割引率作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '割引商品',
              price: 999,
              quantity: 1,
              quantity_unit: '個',
              discount_rate: 10.5,
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      item = receipt.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(item.original_line_total).to eq(999)
        expect(item.discount_amount).to eq(105)
        expect(item.discount_rate).to eq(BigDecimal('0.105'))
        expect(item.line_total).to eq(894)
        expect(receipt.total_amount).to eq(894)
      end
    end

    it '空の新規明細行はline_total 0の明細として保存しない' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '空明細除外',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '',
                category: '',
                price: '',
                quantity: '1',
                quantity_unit: '個',
                product_code: '',
                discount_rate: '',
                tax_rate: '',
                line_total: '0',
                needs_review: false
              }
            }
          }
        }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.receipt_items).to be_empty
        expect(receipt.total_amount).to eq(0)
      end
    end

    it '空欄quantityは1として保存し、price/tax_rate/discount_rateの空欄はnilを維持する' do
      post receipts_path, params: {
        receipt: {
          store_name: '数量空欄作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '金額未入力商品',
              price: '',
              quantity: '',
              quantity_unit: '個',
              discount_rate: '',
              tax_rate: '',
              line_total: '',
              needs_review: false
            }
          }
        }
      }

      item = Receipt.order(:id).last.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(item.quantity).to eq(BigDecimal('1'))
        expect(item.price).to be_nil
        expect(item.tax_rate).to be_nil
        expect(item.discount_rate).to be_nil
      end
    end

    it '明示的な0円明細は保存できる' do
      post receipts_path, params: {
        receipt: {
          store_name: '0円明細作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '0円商品',
              price: '0',
              quantity: '',
              quantity_unit: '個',
              discount_rate: '',
              tax_rate: '',
              line_total: '0',
              needs_review: false
            }
          }
        }
      }

      item = Receipt.order(:id).last.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(item.confirmed_name).to eq('0円商品')
        expect(item.price).to eq(0)
        expect(item.quantity).to eq(BigDecimal('1'))
        expect(item.line_total).to eq(0)
      end
    end

    it '明示的な0のtax_rateとdiscount_rateは0として保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '0率明細作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '0率商品',
              price: '100',
              quantity: '',
              quantity_unit: '個',
              discount_rate: '0',
              tax_rate: '0',
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      item = Receipt.order(:id).last.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(item.quantity).to eq(BigDecimal('1'))
        expect(item.tax_rate).to eq(BigDecimal('0'))
        expect(item.discount_rate).to eq(BigDecimal('0'))
        expect(item.line_total).to eq(100)
      end
    end

    it 'discount_rate 100% はline_totalを0として保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '全額割引作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '全額割引商品',
              price: 310,
              quantity: 1,
              quantity_unit: '個',
              discount_rate: 100,
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      item = receipt.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(item.original_line_total).to eq(310)
        expect(item.discount_amount).to eq(310)
        expect(item.discount_rate).to eq(BigDecimal('1.0'))
        expect(item.line_total).to eq(0)
        expect(receipt.total_amount).to eq(0)
      end
    end

    it 'discount_rate 空欄はdiscount_amount 0として保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '割引なし作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '通常商品',
              price: 310,
              quantity: 1,
              quantity_unit: '個',
              discount_rate: '',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      item = receipt.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(item.original_line_total).to eq(310)
        expect(item.discount_amount).to eq(0)
        expect(item.discount_rate).to be_nil
        expect(item.line_total).to eq(310)
      end
    end

    it '100%を超えるdiscount_rateは保存しない' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '不正割引率作成',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '不正割引商品',
                price: 310,
                quantity: 1,
                quantity_unit: '個',
                discount_rate: 100.1,
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'measurement unitの小数quantityとquantity_unitを保存し、明示line_totalを維持する' do
      post receipts_path, params: {
        receipt: {
          store_name: '量り売り作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '量り売り商品',
              price: 14_400,
              quantity: '0.300',
              quantity_unit: 'kg',
              tax_rate: 10,
              line_total: 4_320,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      item = receipt.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(4_320)
        expect(item.quantity).to eq(BigDecimal('0.300'))
        expect(item.quantity_unit).to eq('kg')
        expect(item.line_total).to eq(4_320)
      end
    end

    it 'decimal comma quantityとcomma区切り金額を保存時に正しく扱う' do
      post receipts_path, params: {
        receipt: {
          store_name: 'decimal comma 作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '量り売り商品',
              price: '14,400',
              quantity: '0,300',
              quantity_unit: '個',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            },
            '1' => {
              confirmed_name: '行合計商品',
              price: nil,
              quantity: 1,
              tax_rate: 10,
              line_total: '4,320',
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      items = receipt.receipt_items.order(:position_index)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(8_640)
        expect(items.first.quantity).to eq(BigDecimal('0.300'))
        expect(items.first.line_total).to eq(4_320)
        expect(items.second.line_total).to eq(4_320)
      end
    end

    it 'measurement unitのline_total nilはprice multiplied by quantityで自動補完しない' do
      post receipts_path, params: {
        receipt: {
          store_name: 'measurement line_total nil 作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '量り売り商品',
              price: 14_400,
              quantity: '0.300',
              quantity_unit: 'kg',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      item = receipt.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).not_to eq(4_320)
        expect(item.quantity).to eq(BigDecimal('0.300'))
        expect(item.quantity_unit).to eq('kg')
        expect(item.line_total).to eq(0)
      end
    end

    it '明細なし手動作成時は入力金額を尊重する' do
      post receipts_path, params: {
        receipt: {
          store_name: '明細なし作成',
          payment_method: 'cash',
          total_amount: 1_100,
          subtotal_amount: 1_000,
          tax_amount: 100,
          tax_rate: 0.1
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(1_100)
        expect(receipt.subtotal_amount).to eq(1_000)
        expect(receipt.tax_amount).to eq(100)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
      end
    end

    it '明細なし手動作成時のcomma区切り入力金額を正しく保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: 'comma金額作成',
          payment_method: 'cash',
          total_amount: '5,000',
          subtotal_amount: '4,546',
          tax_amount: '454',
          tax_rate: 0.1
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(5_000)
        expect(receipt.subtotal_amount).to eq(4_546)
        expect(receipt.tax_amount).to eq(454)
      end
    end

    it '複数税率の明細作成時はreceipt.tax_rateをnilで保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '複数税率作成',
          payment_method: 'cash',
          total_amount: 9_999,
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '軽減税率商品',
              price: 108,
              quantity: 1,
              quantity_unit: '個',
              tax_rate: 8,
              line_total: nil,
              needs_review: false
            },
            '1' => {
              confirmed_name: '標準税率商品',
              price: 110,
              quantity: 1,
              quantity_unit: '個',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(218)
        expect(receipt.subtotal_amount).to eq(200)
        expect(receipt.tax_amount).to eq(18)
        expect(receipt.tax_rate).to be_nil
      end
    end

    it '税率別内訳を保存する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '税率別内訳あり',
            payment_method: 'cash',
            total_amount: 9_999,
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '商品A',
                price: 110,
                quantity: 1,
                quantity_unit: '個',
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            }
          }
        }
      end.to change(ReceiptTaxDetail, :count).by(1)

      tax_detail = Receipt.order(:id).last.receipt_tax_details.first

      aggregate_failures do
        expect(tax_detail.description).to eq('10%対象')
        expect(tax_detail.net_amount).to eq(100)
        expect(tax_detail.amount).to eq(10)
        expect(tax_detail.rate).to eq(BigDecimal('0.1'))
      end
    end

    it 'floor丸めで税額を保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: 'floor丸め作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '丸め確認商品',
              price: 108,
              quantity: 1,
              quantity_unit: '個',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(receipt.total_amount).to eq(108)
        expect(receipt.subtotal_amount).to eq(99)
        expect(receipt.tax_amount).to eq(9)
      end
    end

    it '整合している明細はreview_neededにしない' do
      post receipts_path, params: {
        receipt: {
          store_name: '整合明細',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 110,
              quantity: 1,
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.status).to eq('completed')
        expect(receipt.receipt_items.first.needs_review).to be(false)
      end
    end

    it '対応外形式の画像では作成できない' do
      invalid_file = Rack::Test::UploadedFile.new(
        Tempfile.create([ 'invalid', '.txt' ]).tap { |f| f.write('dummy'); f.rewind }.path,
        'text/plain'
      )

      # Prevent image_tag error in view
      allow_any_instance_of(ActionView::Base).to receive(:image_tag).and_return('')
      # Also stub error mapper locally for safety
      allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_return({ error_category: 'ocr_error' })

      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '不正画像',
            total_amount: 1000,
            payment_method: 'cash',
            image: invalid_file
          }
        }
      end.not_to change(Receipt, :count)

      expect([ 200, 422 ]).to include(response.status)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        post receipts_path, params: valid_params

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'GET /receipts/:id' do
    let(:receipt) do
      create(
        :receipt,
        user: user,
        store_name: 'テスト店',
        total_amount: 1200,
        payment_method: 'cash',
        status: 'completed'
      )
    end

    it '詳細を取得できる' do
      get receipt_path(receipt)

      expect(response).to have_http_status(:success)
    end

    it '詳細画面の主要文言をlocale経由で描画する' do
      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('receipts.show.title'))
        expect(response.body).to include(I18n.t('receipts.show.store_information'))
        expect(response.body).to include(I18n.t('receipts.show.items_title'))
        expect(response.body).to include(I18n.t('receipts.common.total_amount_title'))
      end
    end

    it 'レスポンスにレシート情報が含まれる' do
      get receipt_path(receipt)

      expect(response.body).to include('テスト店')
    end

    it '明細数量をquantity_unit付きで表示し、unitが空なら個として表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit: 'kg',
        line_total: 4_320,
        needs_review: false
      )
      receipt.receipt_items.create!(
        confirmed_name: '通常商品',
        price: 100,
        quantity: 2,
        quantity_unit: nil,
        line_total: 200,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('数量: 0.300 kg')
        expect(response.body).to include('数量: 2 個')
      end
    end

    it 'quantity_unit nil の既存明細は表示上個にfallbackする' do
      receipt.receipt_items.create!(
        confirmed_name: '単位なし商品',
        price: 100,
        quantity: 2,
        quantity_unit: nil,
        line_total: 200,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('数量: 2 個')
      end
    end

    it 'quantity_unit が未知単位でもdetail表示でそのまま表示できる' do
      receipt.receipt_items.create!(
        confirmed_name: '未知単位商品',
        price: 100,
        quantity: BigDecimal('0.300'),
        quantity_unit: '束',
        line_total: 30,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('数量: 0.300 束')
      end
    end

    it '割引明細では割引額と割引率を表示し、右端は割引後小計を維持する' do
      receipt.receipt_items.create!(
        confirmed_name: '割引商品',
        price: 310,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 310,
        discount_amount: 155,
        line_total: 155,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('単価: ¥310')
        expect(response.body).to include('割引: -¥155（50%）')
        expect(response.body).to include('title="¥155"')
      end
    end

    it 'original_line_total がない割引明細では割引率を表示しない' do
      receipt.receipt_items.create!(
        confirmed_name: '率なし割引商品',
        price: 310,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: nil,
        discount_amount: 155,
        line_total: 155,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('割引: -¥155')
        expect(response.body).not_to include('割引: -¥155（')
      end
    end

    it 'discount_amount が 0 の明細では割引表示を出さない' do
      receipt.receipt_items.create!(
        confirmed_name: '通常商品',
        price: 310,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 310,
        discount_amount: 0,
        line_total: 310,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include('割引:')
      end
    end

    it 'failedかつprocessing_error_codeがあるレシートは処理失敗カードを表示する' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'ocr_timeout',
        processing_error_message: 'OCR service timeout'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include('OCR処理に失敗しました')
        expect(response.body).to include('OCR service timeout')
        expect(response.body).to include('手動編集で内容を修正できます')
        expect(response.body).to include('編集して修正')
        expect(response.body).to include(edit_receipt_path(receipt, from: 'show'))
      end
    end

    it 'スマホ詳細ではエラーカードを金額サマリーと店舗情報より先に表示する' do
      receipt.image.attach(uploaded_image)
      receipt.update!(
        status: 'failed',
        processing_error_code: 'ocr_timeout',
        processing_error_message: 'OCR service timeout'
      )

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      alerts = document.at_css('#receipt-detail-alerts')
      sidebar = document.at_css('#receipt-detail-sidebar')
      main = document.at_css('#receipt-detail-main')
      image_card = document.at_css('[data-controller~="receipt-image-card"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(alerts.text).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(alerts['class']).to include('order-1')
        expect(alerts['class']).to include('md:order-2')
        expect(sidebar['class']).to include('order-2')
        expect(sidebar['class']).to include('md:order-1')
        expect(main['class']).to include('order-3')
        expect(main['class']).to include('md:order-3')
        expect(alerts['class']).to include('lg:col-span-8')
        expect(main['class']).to include('lg:col-span-8')
        expect(sidebar['class']).to include('lg:col-start-9')
        expect(sidebar.text).to include(I18n.t('receipts.common.total_amount_title'))
        expect(main.text).to include(I18n.t('receipts.show.store_information'))
        expect(image_card['data-receipt-image-card-initially-open-value']).to eq('true')
        expect(image_card['data-receipt-image-card-collapse-on-mobile-value']).to eq('true')
      end
    end

    it 'エラーなし詳細ではエラー領域を描画しない' do
      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#receipt-detail-alerts')).to be_nil
        expect(document.at_css('#receipt-detail-sidebar')).to be_present
        expect(document.at_css('#receipt-detail-main')).to be_present
      end
    end

    it 'AIがnot receiptと判定したレシートは処理失敗カードに認識失敗文言を表示する' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'ai_not_receipt',
        processing_error_message: 'development_note / not_receipt'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include(I18n.t('receipts.processing_error_codes.ai_not_receipt'))
        expect(response.body).to include('development_note / not_receipt')
        expect(response.body).to include(edit_receipt_path(receipt, from: 'show'))
      end
    end

    it '文字読み取り不可の処理失敗カードは撮影状態の確認文言を表示する' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'no_text_detected'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include('画像から文字を読み取れませんでした。明るさやピントを確認して、別の画像でお試しください。')
      end
    end

    it 'OCR側の非レシート判定はAI側not receiptと同じ認識失敗文言を表示する' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'receipt_not_detected'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include(I18n.t('receipts.processing_error_codes.ai_not_receipt'))
        expect(I18n.t('receipts.processing_error_codes.receipt_not_detected')).to eq(I18n.t('receipts.processing_error_codes.ai_not_receipt'))
      end
    end

    it 'AI一時停止の確認カードはAI失敗ではなく一時停止中として表示する' do
      receipt.update!(
        status: 'review_needed',
        processing_error_code: 'ai_unavailable'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.attention_title'))
        expect(response.body).to include('AI補完は一時停止中です。OCR結果を確認・修正してください。')
        expect(response.body).not_to include('AI補完に失敗しました')
      end
    end

    it 'AI not receiptの不確実ケースは確認系文言を表示する' do
      receipt.update!(
        status: 'review_needed',
        processing_error_code: 'ai_not_receipt_uncertain'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.attention_title'))
        expect(response.body).to include('レシート判定に迷いがあります。OCR結果を確認してください。')
      end
    end

    it 'warningのみのレシートは完了状態のまま確認情報として表示する' do
      receipt.update!(
        status: 'completed',
        review_reasons: [ 'ocr_low_confidence' ]
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('確認情報')
        expect(response.body).to include('OCR品質')
        expect(response.body).to include('画像の精度が低い可能性があります')
        expect(response.body).not_to include('要確認内容')
      end
    end

    it '計算方式推定のwarningは完了状態のまま金額整合性として表示する' do
      receipt.update!(
        status: 'completed',
        review_reasons: [ 'calculation_profile_uncertain' ]
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('確認情報')
        expect(response.body).to include('金額整合性')
        expect(response.body).to include('計算方式を一意に推定できません')
        expect(response.body).not_to include('要確認内容')
      end
    end

    it '税込税抜判定のwarningは確認情報として補足文言を表示する' do
      receipt.update!(
        status: 'completed',
        review_reasons: [ 'price_tax_inclusion_uncertain' ]
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('確認情報')
        expect(response.body).to include('金額整合性')
        expect(response.body).to include('明細金額が税込か税抜かを一意に判定できない箇所があります。必要に応じて小計・税額をご確認ください。')
        expect(response.body).not_to include('要確認内容')
      end
    end

    it '明細税率グループのwarningは確認情報として表示する' do
      receipt.update!(
        status: 'completed',
        review_reasons: [ 'item_tax_rate_group_uncertain' ]
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('確認情報')
        expect(response.body).to include('金額整合性')
        expect(response.body).to include('明細の税率割当と税内訳が一致しない可能性があります。必要に応じて明細ごとの税率をご確認ください。')
        expect(response.body).not_to include('要確認内容')
      end
    end

    it 'AI reasonのみのレシートはAI補完セクションとして表示する' do
      receipt.update!(
        status: 'review_needed',
        review_reasons: [ 'item_name_uncertain' ]
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('要確認内容')
        expect(response.body).to include('AI補完')
        expect(response.body).to include('商品名の精度が低い可能性があります')
      end
    end

    it 'review_neededかつamount blockingのレシートはreview cardを表示する' do
      receipt.update!(
        status: 'review_needed',
        review_reasons: [ 'tax_detail_mismatch' ]
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('要確認内容')
        expect(response.body).to include('金額整合性')
        expect(response.body).to include('税内訳と明細の税額が一致していません')
        expect(response.body).not_to include('処理に失敗しました')
      end
    end

    it 'blockingとwarningが混在するレシートは両方を分離表示する' do
      receipt.update!(
        status: 'review_needed',
        review_reasons: [ 'tax_detail_mismatch', 'ocr_low_confidence' ]
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('要確認内容')
        expect(response.body).to include('金額整合性')
        expect(response.body).to include('税内訳と明細の税額が一致していません')
        expect(response.body).to include('確認情報')
        expect(response.body).to include('OCR品質')
        expect(response.body).to include('画像の精度が低い可能性があります')
      end
    end

    it 'system系reasonはreview cardに表示しない' do
      allow(Analysis::ReceiptProcessingErrorMapper).to receive(:map).and_call_original

      receipt.update!(
        status: 'completed',
        review_reasons: [ 'analysis_missing_keys' ],
        processing_error_code: 'analysis_missing_keys'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('処理に関する注意')
        expect(response.body).to include(I18n.t('receipts.processing_errors.ai_error'))
        expect(response.body).not_to include('要確認内容')
        expect(response.body).not_to include('解析結果に必要な項目が不足しています')
      end
    end

    it '他人のレシートは取得できない' do
      other_user = create(:user, email: 'other@example.com')
      other_receipt = create(
        :receipt,
        user: other_user,
        store_name: '他人のレシート',
        total_amount: 999,
        payment_method: 'cash',
        status: 'completed'
      )

      get receipt_path(other_receipt)

      expect(response).to have_http_status(:not_found)
    end

    it 'processing receipt は詳細へ進めない' do
      processing_receipt = create(:receipt, :processing, :with_image, user: user)

      get receipt_path(processing_receipt)

      expect(response).to redirect_to(receipts_path)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get receipt_path(receipt)

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'GET /receipts/:id/edit' do
    let(:receipt) do
      create(:receipt, user: user, store_name: '編集対象', total_amount: 1300, payment_method: 'cash', status: 'review_needed')
    end

    it '編集画面を取得できる' do
      get edit_receipt_path(receipt)

      expect(response).to have_http_status(:success)
    end

    it '編集画面の主要文言をlocale経由で描画しJS用文言をform data属性へ渡す' do
      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('receipts.form.titles.edit'))
        expect(response.body).to include(I18n.t('receipts.form.buttons.save'))
        expect(response.body).to include(I18n.t('receipts.common.total_amount_title'))
        expect(document.at_css(%(nav[aria-label="#{I18n.t('shared.section_header.breadcrumb_aria')}"]))).to be_present
        expect(form['data-receipt-form-subtotal-label-value']).to eq(I18n.t('receipts.item_fields.subtotal'))
        expect(form['data-receipt-form-unset-label-value']).to eq(I18n.t('receipts.common.unset'))
        expect(form['data-receipt-form-multiple-tax-rates-label-value']).to eq(I18n.t('receipts.common.multiple_tax_rates'))
      end
    end

    it 'receipt image cardにJS用文言をdata属性で渡す' do
      receipt.image.attach(uploaded_image)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      image_card = document.at_css('[data-controller~="receipt-image-card"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(image_card).to be_present
        expect(image_card['data-receipt-image-card-unselected-label-value']).to eq(I18n.t('shared.receipt_image_card.js.unselected'))
        expect(image_card['data-receipt-image-card-empty-file-label-value']).to eq(I18n.t('shared.receipt_image_card.js.empty_file'))
        expect(image_card['data-receipt-image-card-storage-used-bytes-value']).to eq(user.storage_used_bytes.to_s)
        expect(image_card['data-receipt-image-card-storage-limit-bytes-value']).to eq(user.storage_limit_bytes.to_s)
        expect(image_card['data-receipt-image-card-storage-excluding-blob-bytes-value']).to eq(receipt.image.blob.byte_size.to_s)
        expect(image_card['data-receipt-image-card-quota-exceeded-message-value']).to eq(I18n.t('shared.receipt_image_card.quota_exceeded'))
        expect(document.at_css('img[data-receipt-image-card-target="previewImage"]')['src']).to include('/rails/active_storage/')
        expect(document.at_css('input[name="receipt[remove_image]"][value="1"]')).to be_present
        expect(response.body).to include(I18n.t('shared.receipt_image_card.remove_label'))
      end
    end

    it 'receipt_type UIを表示せず電話番号と店舗住所の入力欄は維持する' do
      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to include('レシート種別')
        expect(document.at_css('select[name="receipt[receipt_type]"]')).to be_nil
        expect(document.at_css('input[name="receipt[store_phone_number]"]')).to be_present
        expect(document.at_css('input[name="receipt[store_address]"]')).to be_present
      end
    end

    it 'failedかつprocessing_error_codeがあるレシートは編集画面にも処理失敗カードを表示する' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'ocr_timeout',
        processing_error_message: 'OCR service timeout'
      )

      get edit_receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include('OCR処理に失敗しました')
        expect(response.body).to include('OCR service timeout')
      end
    end

    it 'processing receipt は編集へ進めない' do
      processing_receipt = create(:receipt, :processing, :with_image, user: user)

      get edit_receipt_path(processing_receipt)

      expect(response).to redirect_to(receipts_path)
    end

    it '明細削除確認設定がONならformにconfirm value trueを渡す' do
      user.update!(receipt_item_delete_confirmation_enabled: true)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      aggregate_failures do
        expect(form['data-receipt-form-confirm-item-removal-value']).to eq('true')
        expect(form['data-receipt-form-confirm-item-removal-message-value']).to eq(I18n.t('receipts.form.confirm_item_removal'))
      end
    end

    it '明細削除確認設定がOFFならformにconfirm value falseを渡す' do
      user.update!(receipt_item_delete_confirmation_enabled: false)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      expect(form['data-receipt-form-confirm-item-removal-value']).to eq('false')
    end

    it '外税tax_detailsと金額が整合するレシートではformにexternal basisを渡す' do
      receipt.update!(
        subtotal_amount: 3_903,
        tax_amount: 312,
        total_amount: 4_215,
        tax_rate: BigDecimal('0.08')
      )
      receipt.receipt_items.create!(
        confirmed_name: '外税商品A',
        price: 108,
        quantity: 2,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.08'),
        line_total: 216,
        needs_review: false
      )
      receipt.receipt_items.create!(
        confirmed_name: '外税商品B',
        price: 3_687,
        quantity: 1,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.08'),
        line_total: 3_687,
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.08'),
        net_amount: 3_903,
        amount: 312,
        description: '8%対象'
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(form['data-receipt-form-receipt-tax-basis-value']).to eq('external')
      end
    end

    it 'quantity_unitを編集できるselectを表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit: 'kg',
        line_total: 4_320,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('quantity_unit')
        expect(response.body).to include('kg')
        expect(response.body).to include('その他')
      end
    end

    it 'receipt-level warningを編集画面の確認情報として表示し明細詳細パネルには出さない' do
      receipt.update!(
        status: 'completed',
        review_reasons: [ 'price_tax_inclusion_uncertain' ]
      )
      receipt.receipt_items.create!(
        confirmed_name: '通常商品',
        price: 310,
        quantity: 1,
        quantity_unit: '個',
        line_total: 310,
        needs_review: false,
        review_reasons: []
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      item_name_input = document.at_css('input[value="通常商品"]')
      item_row = item_name_input.ancestors.find { |node| node['data-receipt-form-target'].to_s == 'itemRow' }
      item_details_panel = item_row.at_css('[data-receipt-form-target="itemDetailsPanel"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('確認情報')
        expect(response.body).to include('金額整合性')
        expect(response.body).to include('明細金額が税込か税抜かを一意に判定できない箇所があります。必要に応じて小計・税額をご確認ください。')
        expect(response.body).not_to include('要確認内容')
        expect(item_details_panel.at_css('.receipt-form-item-warning-notes')).to be_nil
      end
    end

    it '明細行とNEW_RECORDテンプレートのStimulus接続を維持する' do
      receipt.receipt_items.create!(
        confirmed_name: '接続確認商品',
        price: 310,
        quantity: 1,
        quantity_unit: '個',
        discount_rate: BigDecimal('0.5'),
        original_line_total: 310,
        line_total: 155,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')
      item_row = document.at_css('[data-receipt-form-target="itemRow"]')
      template = document.at_css('template[data-receipt-form-target="template"]')
      template_html = template&.inner_html.to_s

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(form['data-receipt-form-confirm-item-removal-value']).to eq('true')
        expect(item_row).to be_present
        expect(item_row['data-action']).to include('mouseenter->receipt-form#scheduleLineTotalTooltip')
        expect(item_row['data-action']).to include('mouseleave->receipt-form#hideLineTotalTooltip')
        expect(item_row['data-action']).to include('focusin->receipt-form#hideLineTotalTooltipOnFocus')
        expect(template_html).to include('NEW_RECORD')

        %w[
          quantityInput
          quantityUnitInput
          priceInput
          discountRateInput
          taxRateInput
          lineTotalInput
          lineTotalDisplay
          lineTotalTooltip
          destroyField
          itemDetailsPanel
          itemDetailsToggle
          itemDetailsIcon
        ].each do |target|
          expect(document.css(%([data-receipt-form-target="#{target}"]))).to be_present
        end

        item_details_toggle = item_row.at_css('[data-receipt-form-target="itemDetailsToggle"]')
        item_details_panel = item_row.at_css('[data-receipt-form-target="itemDetailsPanel"]')
        mobile_summary = item_row.at_css('.receipt-form-item-mobile-summary')

        expect(item_details_toggle['data-action']).to include('click->receipt-form#toggleItemDetails')
        expect(item_details_toggle['aria-expanded']).to eq('false')
        expect(item_details_panel['class']).to include('hidden')
        expect(item_details_panel.at_css('[data-receipt-form-target="discountRateInput"]')).to be_present
        expect(item_details_panel.at_css('[data-receipt-form-target="taxRateInput"]')).to be_present
        expect(item_details_panel.at_css('[data-receipt-form-target="lineTotalDisplay"]')).to be_present
        expect(item_details_panel.at_css('select[name$="[category]"]')).to be_present
        expect(template_html).to include('data-receipt-form-target="itemDetailsToggle"')
        expect(template_html).to include('data-receipt-form-target="itemDetailsPanel"')
        expect(template_html).to include('data-receipt-form-target="itemDetailsIcon"')
        expect(template_html).to include('click-&gt;receipt-form#toggleItemDetails')

        expect(mobile_summary).to be_present
        expect(mobile_summary['class']).to include('md:hidden')
        expect(mobile_summary.at_css('.section-divider-line')).to be_present
        expect(mobile_summary.at_css('[data-action="click->receipt-form#removeItem"]')).to be_present
        expect(mobile_summary.at_css('.receipt-form-item-mobile-subtotal [data-receipt-form-target="lineTotalDisplay"]')).to be_present
        expect(mobile_summary.at_css('.receipt-form-item-mobile-subtotal')['class']).not_to include('border')
        expect(item_row.at_css('.receipt-form-item-mobile-name-toggle[data-receipt-form-target="itemDetailsToggle"]')).to be_present
        mobile_detail_divider = item_row.at_css('.receipt-form-item-mobile-detail-divider')
        expect(mobile_detail_divider).to be_present
        expect(mobile_detail_divider['class']).to include('md:hidden')
        expect(mobile_detail_divider.at_css('.section-divider-line')).to be_present
        expect(item_details_panel.at_css('.receipt-form-item-detail-subtotal')['class']).to include('hidden')
        expect(item_details_panel.at_css('.receipt-form-item-detail-subtotal')['class']).to include('md:flex')
        expect(template_html).to include('receipt-form-item-mobile-summary')
        expect(template_html).to include('receipt-form-item-mobile-detail-divider')
        expect(template_html.scan('receipt-form-item-mobile-detail-field').size).to eq(2)

        %w[
          quantityInput
          priceInput
          discountRateInput
          taxRateInput
        ].each do |target|
          input = item_row.at_css(%([data-receipt-form-target="#{target}"]))
          expect(input['data-action']).to include('input->receipt-form#recalculate')
        end

        quantity_wrapper = item_row.at_css('[data-receipt-form-target="quantityInput"]').ancestors.find { |node| node['class'].to_s.include?('receipt-form-item-mobile-detail-field') }
        price_wrapper = item_row.at_css('[data-receipt-form-target="priceInput"]').ancestors.find { |node| node['class'].to_s.include?('receipt-form-item-mobile-detail-field') }

        expect(quantity_wrapper).to be_present
        expect(quantity_wrapper['class']).to include('md:col-span-2')
        expect(price_wrapper).to be_present
        expect(price_wrapper['class']).to include('md:col-span-2')

        %w[
          quantityInput
          quantityUnitInput
          priceInput
          discountRateInput
          taxRateInput
        ].each do |target|
          expect(item_row.css(%([data-receipt-form-target="#{target}"])).size).to eq(1)
        end

        quantity_unit_select = item_row.at_css('[data-receipt-form-target="quantityUnitInput"]')
        expect(quantity_unit_select['data-action']).to be_nil
        expect(quantity_unit_select['aria-label']).to eq(I18n.t('receipts.item_fields.unit'))
        expect(item_row.at_css(%(button[aria-label="#{I18n.t('shared.number_field.decrement_aria', label: I18n.t('receipts.item_fields.unit_price'))}"]))).to be_present
        expect(item_row.at_css(%(button[aria-label="#{I18n.t('shared.number_field.increment_aria', label: I18n.t('receipts.item_fields.unit_price'))}"]))).to be_present

        line_total_input = item_row.at_css('[data-receipt-form-target="lineTotalInput"]')
        expect(line_total_input['data-original-line-total']).to eq('310')
        expect(template_html).to include('data-original-line-total="0"')

        expect(item_row.at_css('[data-receipt-form-target="destroyField"]')).to be_present
        expect(template_html).not_to include('data-receipt-form-target="destroyField"')
        expect(document.css('[data-action="click->receipt-form#removeItem"]').size).to be >= 2
      end
    end

    it '明細のwarning reasonを詳細パネル内の確認情報として表示する' do
      receipt.receipt_items.create!(
        confirmed_name: 'warning確認商品',
        price: 0,
        quantity: 1,
        quantity_unit: '個',
        line_total: 0,
        needs_review: false,
        review_reasons: [ 'zero_amount_item_incomplete' ]
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      item_name_input = document.at_css('input[value="warning確認商品"]')
      item_row = item_name_input.ancestors.find { |node| node['data-receipt-form-target'].to_s == 'itemRow' }
      item_details_panel = item_row.at_css('[data-receipt-form-target="itemDetailsPanel"]')
      warning_block = item_details_panel.at_css('.receipt-form-item-warning-notes')
      template_html = document.at_css('template[data-receipt-form-target="template"]')&.inner_html.to_s

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(item_row['class']).not_to include('receipt-form-item-review-row')
        expect(warning_block).to be_present
        expect(warning_block.text).to include('確認情報')
        expect(warning_block.text).to include('0円明細の金額情報が一部不足しています')
        expect(template_html).not_to include('receipt-form-item-warning-notes')
        expect(template_html).not_to include('0円明細の金額情報が一部不足しています')
      end
    end

    it '数量入力の初期表示では末尾ゼロを落とす' do
      [
        [ '整数1', BigDecimal('1.0'), '1' ],
        [ '整数2', BigDecimal('2.0'), '2' ],
        [ '小数1.5', BigDecimal('1.5'), '1.5' ],
        [ '小数0.5', BigDecimal('0.5'), '0.5' ],
        [ '小数0.300', BigDecimal('0.300'), '0.3' ]
      ].each do |name, quantity, _expected_value|
        receipt.receipt_items.create!(
          confirmed_name: name,
          price: 100,
          quantity: quantity,
          quantity_unit: '個',
          line_total: 100,
          needs_review: false
        )
      end

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_values = document.css('[data-receipt-form-target="quantityInput"]').map { |input| input['value'] }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_values).to include('1', '2', '1.5', '0.5', '0.3')
        expect(quantity_values).not_to include('1.0', '2.0')
      end
    end

    it 'quantityがnilの既存明細は編集フォームで1として表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '数量未入力商品',
        price: 500,
        quantity: nil,
        quantity_unit: '個',
        line_total: 500,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      item_name_input = document.at_css('input[value="数量未入力商品"]')
      item_row = item_name_input.ancestors.find { |node| node['data-receipt-form-target'].to_s == 'itemRow' }
      quantity_input = item_row.at_css('[data-receipt-form-target="quantityInput"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_input['value']).to eq('1')
      end
    end

    it '既存割引額からdiscount_rate入力値を表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '割引商品',
        price: 310,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 310,
        discount_amount: 155,
        line_total: 155,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      discount_rate_input = document.at_css('input[name$="[discount_rate]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(discount_rate_input['value']).to eq('50')
      end
    end

    it 'discount_rate入力をreceipt formの再計算に接続する' do
      receipt.receipt_items.create!(
        confirmed_name: '割引商品',
        price: 310,
        quantity: 1,
        quantity_unit: '個',
        line_total: 310,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      discount_rate_input = document.at_css('input[name$="[discount_rate]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(discount_rate_input['data-receipt-form-target']).to eq('discountRateInput')
        expect(discount_rate_input['data-action']).to include('input->receipt-form#recalculate')
      end
    end

    it '既存の印字済みline_totalをdiscount_rate再計算で崩さないJS情報を持つ' do
      receipt.receipt_items.create!(
        confirmed_name: '印字済み割引商品',
        price: 999,
        quantity: 1,
        quantity_unit: '個',
        original_line_total: 999,
        discount_rate: BigDecimal('0.105'),
        discount_amount: 104,
        line_total: 895,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      discount_rate_input = document.at_css('input[name$="[discount_rate]"]')
      line_total_input = document.at_css('input[name$="[line_total]"]')
      controller_source = Rails.root.join('app/javascript/controllers/receipt_form_controller.js').read

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(discount_rate_input['value']).to eq('10.5')
        expect(discount_rate_input['data-original-discount-rate']).to eq('10.5')
        expect(line_total_input['value']).to eq('895')
        expect(line_total_input['data-original-line-total']).to eq('999')
        expect(controller_source).to include('shouldPreserveExistingLineTotal')
        expect(controller_source).to include('discountRateWasEdited')
      end
    end

    it '数量入力だけdecimal commaを許可する' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit: 'kg',
        line_total: 4_320,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_input = document.at_css('[data-receipt-form-target="quantityInput"]')
      price_input = document.at_css('[data-receipt-form-target="priceInput"]')
      quantity_field = quantity_input.ancestors.find { |node| node['data-controller'].to_s.split.include?('number-field') }
      price_field = price_input.ancestors.find { |node| node['data-controller'].to_s.split.include?('number-field') }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_field['data-number-field-decimal-comma-value']).to eq('true')
        expect(price_field['data-number-field-decimal-comma-value']).to be_nil
      end
    end

    it '数量単位selectを再計算判定targetとして表示し、unit変更だけでは再計算しない' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit: 'kg',
        line_total: 4_320,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_unit_select = document.at_css('select[name$="[quantity_unit]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_unit_select['data-receipt-form-target']).to eq('quantityUnitInput')
        expect(quantity_unit_select['data-action']).to be_nil
      end
    end

    it 'measurement unitへ変更後も後続再計算で新規明細の算出済み小計を保持できるJS同期を持つ' do
      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      template_html = document.at_css('template[data-receipt-form-target="template"]')&.inner_html.to_s
      controller_source = Rails.root.join('app/javascript/controllers/receipt_form_controller.js').read

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(template_html).to include('data-original-line-total="0"')
        expect(template_html).to include('data-receipt-form-target="quantityUnitInput"')
        expect(template_html).not_to include('data-action="change-&gt;receipt-form#recalculate"')
        expect(controller_source).to include('syncLineTotalState')
        expect(controller_source).to include('lineTotalInput.dataset.originalLineTotal = String(originalLineTotal)')
      end
    end

    it 'countable unitとmeasurement unitを選択肢として表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '単位確認商品',
        price: 100,
        quantity: 1,
        quantity_unit: '個',
        line_total: 100,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      option_values = document.css('select[name$="[quantity_unit]"] option').map { |option| option['value'] }.uniq

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(option_values).to include('個', '点', '本', '袋', '枚', '台', '箱', 'セット')
        expect(option_values).to include('kg', 'g', 'mg', 'L', 'ml', 'cc')
      end
    end

    it '未知quantity_unitの既存明細は現在値を選択肢として保持する' do
      receipt.receipt_items.create!(
        confirmed_name: '未知単位商品',
        price: 100,
        quantity: BigDecimal('0.300'),
        quantity_unit: '束',
        line_total: 30,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_unit_select = document.at_css('select[name$="[quantity_unit]"]')
      selected_option = quantity_unit_select.at_css('option[selected]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_unit_select.css('option').map { |option| option['value'] }).to include('束')
        expect(selected_option['value']).to eq('束')
      end
    end

    it '他人のレシート編集画面は取得できない' do
      other_user = create(:user, email: 'edit_other@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人編集', total_amount: 900, payment_method: 'cash', status: 'completed')

      get edit_receipt_path(other_receipt)

      expect(response).to have_http_status(:not_found)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        get edit_receipt_path(receipt)

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'PATCH /receipts/:id' do
    let(:receipt) do
      create(
        :receipt,
        user: user,
        store_name: '更新前',
        total_amount: 1400,
        payment_method: 'cash',
        status: 'review_needed'
      )
    end

    let(:valid_update_params) do
      {
        receipt: {
          store_name: '更新後',
          total_amount: 2000,
          payment_method: 'credit_card',
          memo: '更新メモ'
        }
      }
    end

    let(:invalid_update_params) do
      {
        receipt: {
          store_name: '',
          total_amount: nil,
          payment_method: 'cash'
        }
      }
    end

    it 'レシートを更新できる' do
      patch receipt_path(receipt), params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.store_name).to eq('更新後')
        expect(receipt.total_amount).to eq(2000)
        expect(receipt.payment_method).to eq('credit_card')
        expect(receipt.memo).to eq('更新メモ')
      end
    end

    it '通知OFFなら更新成功のredirect flashを表示しない' do
      user.update!(push_notification_enabled: false)

      patch receipt_path(receipt), params: valid_update_params

      follow_redirect!
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#flash [data-controller~="notice-surface"]')).to be_nil
        expect(response.body).not_to include(I18n.t('flash.receipts.update'))
      end
    end

    it '不正なパラメータでは更新できない' do
      patch receipt_path(receipt), params: invalid_update_params
      receipt.reload

      aggregate_failures do
        expect([ 200, 422 ]).to include(response.status)
        expect(receipt.store_name).to eq('更新前')
        expect(receipt.total_amount).to eq(1400)
      end
    end

    it '画像差し替えを含むvalidation失敗時もsigned_id errorにならず編集フォームに戻る' do
      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え失敗',
          total_amount: 1500,
          payment_method: 'cash',
          memo: 'x' * 1001,
          image: uploaded_image
        }
      }
      receipt.reload
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(receipt.store_name).to eq('更新前')
        expect(receipt.total_amount).to eq(1400)
        expect(receipt.memo).to be_blank
        expect(response.body).to include(I18n.t('receipts.form.titles.edit'))
        expect(document.at_css('#flash [data-controller~="notice-surface"]')).to be_present
        expect(response.body).to include(I18n.t('shared.receipt_image_card.reselect_image'))
        expect(response.body).not_to include('Cannot get a signed_id')
      end
    end

    it '画像差し替え時も再解析は実行せず編集保存する' do
      allow(ReceiptAnalysisService).to receive(:call)

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え後',
          total_amount: 2100,
          payment_method: 'cash',
          image: uploaded_image
        }
      }
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(ReceiptAnalysisService).not_to have_received(:call)
      end
    end

    it '画像差し替え時は解析失敗処理も実行しない' do
      allow(ReceiptAnalysisService).to receive(:call)

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え失敗なし',
          total_amount: 2200,
          payment_method: 'cash',
          image: uploaded_image
        }
      }
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(ReceiptAnalysisService).not_to have_received(:call)
        expect(receipt.processing_error_code).to be_nil
      end
    end

    it '画像差し替え時は既存blob分を差し引いて容量判定する' do
      receipt.image.attach(uploaded_image)
      user.update!(storage_limit_bytes: receipt.image.blob.byte_size)

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え容量OK',
          total_amount: 2200,
          payment_method: 'cash',
          image: Rack::Test::UploadedFile.new(image_path, 'image/jpeg')
        }
      }

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.image).to be_attached
      end
    end

    it '画像差し替え時に容量上限を超える場合は更新しない' do
      user.update!(storage_limit_bytes: 1)

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え容量NG',
          total_amount: 2200,
          payment_method: 'cash',
          image: uploaded_image
        }
      }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.storage.quota_exceeded'))
        expect(receipt.reload.store_name).to eq('更新前')
      end
    end

    it 'remove_image=1で既存画像を削除する' do
      receipt.image.attach(uploaded_image)
      old_blob = receipt.image.blob

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像削除後',
          total_amount: 2200,
          payment_method: 'cash',
          remove_image: '1'
        }
      }

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.image).not_to be_attached
        expect(ActiveStorage::Blob.exists?(old_blob.id)).to be(false)
      end
    end

    it 'validation失敗時はremove_image=1でも既存画像を削除しない' do
      receipt.image.attach(uploaded_image)
      old_blob = receipt.image.blob

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像削除失敗',
          total_amount: 2200,
          payment_method: 'cash',
          memo: 'x' * 1001,
          remove_image: '1'
        }
      }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(receipt.reload.image).to be_attached
        expect(receipt.image.blob.id).to eq(old_blob.id)
      end
    end

    it 'remove_image=1と新規画像が同時に送られた場合は新規画像を優先する' do
      receipt.image.attach(uploaded_image)
      old_blob = receipt.image.blob

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像差し替え優先',
          total_amount: 2200,
          payment_method: 'cash',
          image: Rack::Test::UploadedFile.new(image_path, 'image/jpeg'),
          remove_image: '1'
        }
      }

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.image).to be_attached
        expect(receipt.image.blob.id).not_to eq(old_blob.id)
      end
    end

    it '画像削除後はstorage_used_bytesが減る' do
      receipt.image.attach(uploaded_image)
      expect(user.storage_used_bytes).to be_positive

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '画像削除容量反映',
          total_amount: 2200,
          payment_method: 'cash',
          remove_image: '1'
        }
      }

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(user.storage_used_bytes).to eq(0)
      end
    end

    it '画像差し替えなし更新時は再解析を実行しない' do
      allow(ReceiptAnalysisService).to receive(:call)

      patch receipt_path(receipt), params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(ReceiptAnalysisService).not_to have_received(:call)
      end
    end

    it 'failed receipt を手動編集保存するとcompletedに戻しprocessing errorを消す' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'ocr_timeout',
        processing_error_message: 'OCR service timeout'
      )

      patch receipt_path(receipt), params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
      end
    end

    it 'review_needed receipt は手動編集保存してもstatusを維持しprocessing errorだけ消す' do
      receipt.update!(
        status: 'review_needed',
        processing_error_code: 'ai_invalid_response',
        processing_error_message: 'AI response invalid',
        review_reasons: [ 'tax_detail_mismatch' ]
      )

      patch receipt_path(receipt), params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.review_reasons).to include('tax_detail_mismatch')
      end
    end

    it '明細変更時に金額を再計算して保存する' do
      item = receipt.receipt_items.create!(
        confirmed_name: '更新前商品',
        price: 110,
        quantity: 1,
        tax_rate: BigDecimal('0.1'),
        line_total: 110,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '明細更新後',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '更新後商品',
              price: 108,
              quantity: 2,
              tax_rate: 10,
              line_total: 216,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(216)
        expect(receipt.subtotal_amount).to eq(197)
        expect(receipt.tax_amount).to eq(19)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(item.line_total).to eq(216)
      end
    end

    it '外税tax_detailsと整合する明細を保存しても外税のsubtotal tax totalとtax_detailsを維持する' do
      receipt.update!(
        store_name: '外税更新前',
        subtotal_amount: 3_903,
        tax_amount: 312,
        total_amount: 4_215,
        tax_rate: BigDecimal('0.08')
      )
      item_a = receipt.receipt_items.create!(
        confirmed_name: '外税商品A',
        price: 108,
        quantity: 2,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.08'),
        line_total: 216,
        needs_review: false
      )
      item_b = receipt.receipt_items.create!(
        confirmed_name: '外税商品B',
        price: 3_687,
        quantity: 1,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.08'),
        line_total: 3_687,
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.08'),
        net_amount: 3_903,
        amount: 312,
        description: '8%対象'
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '外税更新後',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item_a.id,
              confirmed_name: item_a.confirmed_name,
              price: 108,
              quantity: 2,
              quantity_unit: '個',
              tax_rate: 8,
              line_total: 216,
              needs_review: false
            },
            '1' => {
              id: item_b.id,
              confirmed_name: item_b.confirmed_name,
              price: 3_687,
              quantity: 1,
              quantity_unit: '個',
              tax_rate: 8,
              line_total: 3_687,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      tax_detail = receipt.receipt_tax_details.first

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.subtotal_amount).to eq(3_903)
        expect(receipt.tax_amount).to eq(312)
        expect(receipt.total_amount).to eq(4_215)
        expect(tax_detail.net_amount).to eq(3_903)
        expect(tax_detail.amount).to eq(312)
        expect(tax_detail.rate).to eq(BigDecimal('0.08'))
      end
    end

    it '更新時のdiscount_rate入力をdiscount_amountへ変換しdiscount_rateも保存する' do
      item = receipt.receipt_items.create!(
        confirmed_name: '割引更新前商品',
        price: 300,
        quantity: 2,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.1'),
        line_total: 600,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '割引率更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '割引更新後商品',
              price: 300,
              quantity: 2,
              quantity_unit: '個',
              discount_rate: 50,
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.original_line_total).to eq(600)
        expect(item.discount_amount).to eq(300)
        expect(item.discount_rate).to eq(BigDecimal('0.5'))
        expect(item.line_total).to eq(300)
        expect(receipt.total_amount).to eq(300)
      end
    end

    it 'measurement unitの小数quantityとquantity_unitを更新し、明示line_totalを維持できる' do
      item = receipt.receipt_items.create!(
        confirmed_name: '更新前量り売り商品',
        price: 100,
        quantity: 1,
        quantity_unit: nil,
        tax_rate: BigDecimal('0.1'),
        line_total: 100,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '小数数量更新後',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '更新後量り売り商品',
              price: 14_400,
              quantity: '0.300',
              quantity_unit: 'kg',
              tax_rate: 10,
              line_total: 4_320,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(4_320)
        expect(item.quantity).to eq(BigDecimal('0.300'))
        expect(item.quantity_unit).to eq('kg')
        expect(item.line_total).to eq(4_320)
      end
    end

    it 'unit変更のみのPATCHではline_totalを変えない' do
      item = receipt.receipt_items.create!(
        confirmed_name: '単位だけ変更する商品',
        price: 9_999,
        quantity: 9,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.1'),
        line_total: 200,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '単位だけ更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit: 'kg',
              tax_rate: 10,
              line_total: item.line_total,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.quantity_unit).to eq('kg')
        expect(item.line_total).to eq(200)
        expect(receipt.total_amount).to eq(200)
      end
    end

    it 'countable unitはquantity変更でline_totalを再計算する' do
      item = receipt.receipt_items.create!(
        confirmed_name: '個数商品',
        price: 500,
        quantity: 2,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_000,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '個数商品更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 500,
              quantity: 3,
              quantity_unit: '個',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.line_total).to eq(1_500)
        expect(receipt.total_amount).to eq(1_500)
      end
    end

    it '既存明細のquantity空欄保存は1として扱う' do
      item = receipt.receipt_items.create!(
        confirmed_name: '数量空欄更新商品',
        price: 500,
        quantity: 2,
        quantity_unit: '個',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_000,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '数量空欄更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 500,
              quantity: '',
              quantity_unit: '個',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.quantity).to eq(BigDecimal('1'))
        expect(item.line_total).to eq(500)
      end
    end

    it 'measurement unitはquantity変更でもline_totalを維持する' do
      item = receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit: 'kg',
        tax_rate: BigDecimal('0.1'),
        line_total: 4_320,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '量り売り更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 14_400,
              quantity: '0.500',
              quantity_unit: 'kg',
              tax_rate: 10,
              line_total: 4_320,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.quantity).to eq(BigDecimal('0.500'))
        expect(item.line_total).to eq(4_320)
        expect(receipt.total_amount).to eq(4_320)
      end
    end

    it '未知quantity_unitはそのままPATCHしても維持される' do
      item = receipt.receipt_items.create!(
        confirmed_name: '未知単位商品',
        price: 100,
        quantity: BigDecimal('0.300'),
        quantity_unit: '束',
        tax_rate: BigDecimal('0.1'),
        line_total: 30,
        needs_review: false
      )

      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '未知単位更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: '0.300',
              quantity_unit: '束',
              tax_rate: 10,
              line_total: item.line_total,
              needs_review: false
            }
          }
        }
      }

      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.quantity_unit).to eq('束')
        expect(item.line_total).to eq(30)
      end
    end

    it '明細なし編集保存時は入力金額を尊重する' do
      patch receipt_path(receipt), params: {
        receipt: {
          store_name: '明細なし更新',
          payment_method: 'cash',
          total_amount: 3_300,
          subtotal_amount: 3_000,
          tax_amount: 300,
          tax_rate: 0.1
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(3_300)
        expect(receipt.subtotal_amount).to eq(3_000)
        expect(receipt.tax_amount).to eq(300)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
      end
    end

    it '他人のレシートは更新できない' do
      other_user = create(:user, email: 'update_other@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人更新前', total_amount: 800, payment_method: 'cash', status: 'completed')

      patch receipt_path(other_receipt), params: valid_update_params

      expect(response).to have_http_status(:not_found)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        patch receipt_path(receipt), params: valid_update_params

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'DELETE /receipts/:id' do
    let!(:receipt) do
      create(:receipt, user: user, store_name: '削除対象', total_amount: 1500, payment_method: 'cash', status: 'completed')
    end

    it 'レシートを削除できる' do
      expect do
        delete receipt_path(receipt)
      end.to change(Receipt, :count).by(-1)

      expect(response).to redirect_to(receipts_path)
    end

    it '通知OFFなら削除成功のredirect flashを表示しない' do
      user.update!(push_notification_enabled: false)

      delete receipt_path(receipt)

      follow_redirect!
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#flash [data-controller~="notice-surface"]')).to be_nil
        expect(response.body).not_to include(I18n.t('flash.receipts.destroy'))
      end
    end

    it '他人のレシートは削除できない' do
      other_user = create(:user, email: 'destroy_other@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人削除', total_amount: 700, payment_method: 'cash', status: 'completed')

      expect do
        delete receipt_path(other_receipt)
      end.not_to change(Receipt, :count)

      expect(response).to have_http_status(:not_found)
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        delete receipt_path(receipt)

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end
end
