require 'rails_helper'
require 'zlib'

RSpec.describe 'Receipts', type: :request do
  include ActiveJob::TestHelper

  let(:user) { create(:user) }
  let(:image_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:uploaded_image) do
    Rack::Test::UploadedFile.new(image_path, 'image/jpeg')
  end

  def uploaded_receipt_fixture(filename = 'receipt_sample.jpg', content_type = 'image/jpeg')
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files', filename), content_type)
  end

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

  def uploaded_png(width:, height:)
    tempfile = Tempfile.new([ "receipt-#{width}x#{height}", ".png" ])
    tempfile.binmode
    tempfile.write(png_bytes(width: width, height: height))
    tempfile.rewind

    Rack::Test::UploadedFile.new(tempfile.path, 'image/png')
  end

  def uploaded_bytes(prefix:, extension:, content_type:, bytes:)
    tempfile = extension.present? ? Tempfile.new([ prefix, extension ]) : Tempfile.new(prefix)
    tempfile.binmode
    tempfile.write(bytes)
    tempfile.rewind

    Rack::Test::UploadedFile.new(tempfile.path, content_type)
  end

  def rendered_receipt_item_rows(document)
    document.css('[data-receipt-form-target="itemsContainer"] > [data-controller~="swipe-action"] [data-receipt-form-target="itemRow"]')
  end

  def rendered_receipt_payment_rows(document)
    document.css('[data-receipt-form-target="paymentsContainer"] > [data-controller~="swipe-action"] [data-receipt-form-target="paymentRow"]')
  end

  def amount_summary_tax_rate_value(document)
    tax_rate_label = I18n.t('shared.amount_summary_card.tax_rate')
    row = document.css('div').find do |node|
      spans = node.xpath('./span')
      spans.first&.text&.strip == tax_rate_label
    end

    row&.xpath('./span')&.last&.text&.strip
  end

  def receipt_card_ids(document)
    document.css('#receipts-list-grid > [id^="receipt_"]').map { |node| node['id'] }
  end

  def receipt_index_controls(document)
    document.at_css('#receipt-index-controls')
  end

  def logout_confirm_value(sign_out_form)
    sign_out_form['data-turbo-confirm'] || sign_out_form.at_css('button')&.[]('data-turbo-confirm')
  end

  def logout_confirm_data_value(sign_out_form, name)
    sign_out_form[name] || sign_out_form.at_css('button')&.[](name)
  end

  def manual_item_params(index)
    {
      confirmed_name: "商品#{index}",
      price: 100,
      quantity: 1,
      quantity_unit_code: 'each',
      line_total: 100,
      needs_review: false
    }
  end

  def manual_items_params(count)
    (0...count).to_h { |index| [ index.to_s, manual_item_params(index) ] }
  end

  def manual_adjustment_params(index)
    {
      kind: 'delivery_fee',
      label: "調整#{index}",
      amount: 10,
      sign: 'surcharge',
      tax_rate: '10',
      position_index: index
    }
  end

  def manual_payment_params(index)
    {
      method: "method-#{index}",
      amount: 100
    }
  end

  def manual_tax_detail_params(index)
    {
      description: "税内訳#{index}",
      amount: 10,
      rate: 10,
      net_amount: 100
    }
  end

  def selected_receipt_index_control(document, name)
    receipt_index_controls(document).at_css("select[name='#{name}'] option[selected]")&.[]('value')
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
        country_region: 'JPN',
        items: [
          {
            raw_text: 'コーヒー',
            price: 180,
            quantity: 1,
            quantity_unit_code: 'each',
            line_total: 180,
            tax_rate: 10,
            confidence: 0.98
          },
          {
            raw_text: 'サンド',
            price: 550,
            quantity: 2,
            quantity_unit_code: 'each',
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

  def perform_analysis_job_chain(run)
    perform_enqueued_jobs(only: [ ReceiptAiEnrichmentJob, ReceiptFinalizeJob ]) do
      ReceiptOcrJob.perform_now(run_id: run.id)
    end
  end

  before do
    sign_in user
    allow(Analysis).to receive(:processing_error_mapping).and_return({ error_category: 'ocr_error' })
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

    it 'ヘッダーのログアウト導線はJSなしでもDELETE送信できるformを描画する' do
      get receipts_path

      document = Nokogiri::HTML(response.body)
      sign_out_form = document.at_css("form[action='#{destroy_user_session_path}'][method='post']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(sign_out_form).to be_present
        expect(sign_out_form.at_css('input[name="_method"]')['value']).to eq('delete')
        expect(sign_out_form.at_css('button')).to be_present
        expect(sign_out_form.text).to include(I18n.t('common.logout'))
        expect(logout_confirm_value(sign_out_form)).to eq(I18n.t('dashboard.header.logout_confirm'))
        expect(logout_confirm_data_value(sign_out_form, 'data-confirm-variant')).to eq('neutral')
        expect(logout_confirm_data_value(sign_out_form, 'data-confirm-icon')).to eq('logout')
        expect(logout_confirm_data_value(sign_out_form, 'data-confirm-confirm-label')).to eq(I18n.t('common.logout'))
      end
    end

    it 'guestのログアウト導線は再アクセス不可の可能性をconfirmで警告する' do
      sign_out user
      guest = create(:user, guest: true)
      sign_in guest

      get receipts_path

      document = Nokogiri::HTML(response.body)
      sign_out_form = document.at_css("form[action='#{destroy_user_session_path}'][method='post']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(sign_out_form).to be_present
        expect(sign_out_form.at_css('input[name="_method"]')['value']).to eq('delete')
        expect(logout_confirm_value(sign_out_form)).to eq(I18n.t('dashboard.header.logout_confirm_guest'))
        expect(logout_confirm_data_value(sign_out_form, 'data-confirm-variant')).to eq('neutral')
        expect(logout_confirm_data_value(sign_out_form, 'data-confirm-icon')).to eq('logout')
        expect(logout_confirm_data_value(sign_out_form, 'data-confirm-confirm-label')).to eq(I18n.t('common.logout'))
      end
    end

    it 'JS無効案内はdashboardのmain領域内に描画する' do
      get receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('body > noscript')).to be_nil
        expect(document.at_css('main noscript')).to be_present
        expect(document.at_css('main noscript').text).to include(I18n.t('shared.noscript.title'))
      end
    end

    it '自分のレシートだけが表示される' do
      get receipts_path

      aggregate_failures do
        expect(response.body).to include('自分のレシート')
        expect(response.body).not_to include('他人のレシート')
      end
    end

    it '隔離中のレシートは一覧に表示しない' do
      quarantined_receipt = create(:receipt, :quarantined, user: user, store_name: '隔離中のレシート', status: 'completed')

      get receipts_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('自分のレシート')
        expect(response.body).not_to include('隔離中のレシート')
        expect(receipt_card_ids(Nokogiri::HTML(response.body))).not_to include("receipt_#{quarantined_receipt.public_id}")
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
        expect(results.at_css('#receipts-list-grid')['class'].split).to include('items-start')
        expect(results.at_css('#receipts-empty-state')).to be_nil
      end
    end

    it '処理中カードがある間だけ再同期するcontroller設定を一覧へ描画する' do
      processing_receipt = create(:receipt, :processing, :with_image, user:)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      results = document.at_css('#receipts-results')
      processing_card = document.at_css("##{processing_receipt.dom_target_id}")
      completed_card = document.at_css("##{my_receipt.dom_target_id}")

      aggregate_failures do
        expect(results['data-controller'].split).to include('receipt-processing-sync')
        expect(results['data-receipt-processing-sync-url-value']).to eq(processing_cards_receipts_path)
        expect(results['data-receipt-processing-sync-interval-value']).to eq('3000')
        expect(results['data-receipt-processing-sync-refresh-on-terminal-value']).to eq('false')
        expect(processing_card['data-receipt-processing-sync-target']).to eq('card')
        expect(completed_card['data-receipt-processing-sync-target']).to be_nil
      end
    end

    it '検索中は全体summary broadcastとDOM targetを分けてterminal更新時にscopeを再取得する' do
      get receipts_path(q: my_receipt.store_name)

      document = Nokogiri::HTML(response.body)
      results = document.at_css('#receipts-results')

      aggregate_failures do
        expect(document.at_css('#receipts_search_summary')).to be_present
        expect(document.at_css('#receipts_summary')).to be_nil
        expect(results['data-receipt-processing-sync-refresh-on-terminal-value']).to eq('true')
      end
    end

    it '金額や店舗名に依存するsortではterminal更新時に並び順を再取得する' do
      %w[amount_desc amount_asc store_name updated review_priority].each do |sort|
        get receipts_path(sort: sort)

        document = Nokogiri::HTML(response.body)
        expect(document.at_css('#receipts-results')['data-receipt-processing-sync-refresh-on-terminal-value']).to eq('true')
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

    it 'lowercase display IDと通常tokenでactiveな自分のレシートだけを検索しraw queryを保持する' do
      raw_query = "#{my_receipt.display_id.downcase} #{my_receipt.store_name}"
      text_only = create(
        :receipt,
        :completed,
        user: user,
        store_name: my_receipt.store_name,
        memo: "参照 #{my_receipt.display_id}",
        total_amount: 123
      )
      other_receipt.update!(display_id: my_receipt.display_id)

      get receipts_path(q: raw_query, sort: 'oldest', per_page: 50)

      document = Nokogiri::HTML(response.body)
      card_ids = receipt_card_ids(document)
      search_forms = document.css("form[action='#{receipts_path}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(card_ids).to contain_exactly("receipt_#{my_receipt.public_id}")
        expect(card_ids).not_to include("receipt_#{text_only.public_id}", "receipt_#{other_receipt.public_id}")
        expect(document.css('input[name="q"]').map { |input| input['value'] }.uniq).to eq([ raw_query ])
        expect(search_forms.any? { |form| form.at_css("input[name='sort'][value='oldest']").present? }).to be(true)
        expect(search_forms.any? { |form| form.at_css("input[name='per_page'][value='50']").present? }).to be(true)
      end
    end

    it '他利用者、quarantine、存在しないdisplay IDを同じ通常の0件表示にする' do
      other_user = create(:user)
      create(:receipt, :completed, user: other_user, display_id: 'R-OTHER9', store_name: '他利用者だけ')
      create(
        :receipt,
        :completed,
        :quarantined,
        user: user,
        display_id: 'R-QUAR99',
        store_name: '隔離中だけ'
      )

      %w[R-OTHER9 R-QUAR99 R-MISS99].each do |query|
        get receipts_path(q: query)

        document = Nokogiri::HTML(response.body)
        empty_state = document.at_css('#receipts-empty-state')

        aggregate_failures query do
          expect(response).to have_http_status(:success)
          expect(receipt_card_ids(document)).to be_empty
          expect(empty_state).to be_present
          expect(empty_state.text).to include(I18n.t('receipt_cards.empty.search.title'))
          expect(empty_state.text).not_to include('他利用者', '隔離', '削除')
        end
      end
    end

    it 'public ID列は検索せずpublic-ID-shaped textの既存検索を維持する' do
      text_match = create(
        :receipt,
        :completed,
        user: user,
        store_name: '公開IDメモ',
        memo: "参照 #{my_receipt.public_id}",
        total_amount: 321
      )

      get receipts_path(q: my_receipt.public_id)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(receipt_card_ids(document)).to contain_exactly("receipt_#{text_match.public_id}")
        expect(receipt_card_ids(document)).not_to include("receipt_#{my_receipt.public_id}")
      end
    end

    it 'display ID検索の範囲外pageをraw queryとsort/per_pageを保った1ページ目へcanonicalizeする' do
      raw_query = my_receipt.display_id.downcase

      get receipts_path(q: raw_query, sort: 'oldest', per_page: 50, page: 2)

      expect(response).to redirect_to(
        receipts_path(q: raw_query, sort: 'oldest', per_page: 50, page: 1)
      )
    end

    it '不正パターンを含む検索語の本文をログへ記録しない' do
      query = 'select person@example.test'
      messages = []
      allow(Rails.logger).to receive(:warn) { |message| messages << message.to_s }

      get receipts_path(q: query)

      log = messages.join("\n")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(log).to include('[Receipts::SearchForm] suspicious_query')
        expect(log).to include("user_id=#{user.id}")
        expect(log).to include("query_length=#{query.length}")
        expect(log).not_to include(query, 'person@example.test')
      end
    end

    it '確定した不正date検索条件はHTMLで422を返す' do
      [
        'date>=2026-13-01',
        'date>=2026-02-31',
        'date<=2214-15-99',
        'date:2026-01-01..2026-13-40'
      ].each do |query|
        get receipts_path(q: query)

        aggregate_failures query do
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).not_to include('Date::Error')
          expect(response.body).to include(I18n.t('search.realtime.invalid_query_message'))
        end
      end
    end

    it 'realtime検索の不正date条件はJSON 422を返す' do
      get receipts_path(q: 'date>=2026-13-01'), headers: { 'X-Recify-Search' => 'realtime' }

      payload = JSON.parse(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.media_type).to eq('application/json')
        expect(payload).to include(
          'error' => 'invalid_search_query',
          'message' => I18n.t('search.realtime.invalid_query_message')
        )
      end
    end

    it '入力途中のdateやdate以外の不正風tokenは422にしない' do
      [
        'date:2026-01-01..',
        'date>=2026-',
        'amount>=abc',
        'unknown:xxx'
      ].each do |query|
        get receipts_path(q: query)

        document = Nokogiri::HTML(response.body)

        aggregate_failures query do
          expect(response).to have_http_status(:success)
          expect(response.body).not_to include('Date::Error')
          expect(document.at_css('#receipts-empty-state').text).to include(I18n.t('receipt_cards.empty.search.title'))
        end
      end
    end

    it 'realtime search error文言をdata属性で渡す' do
      get receipts_path

      document = Nokogiri::HTML(response.body)
      search_controller = document.at_css('[data-controller~="search"]')

      aggregate_failures do
        expect(search_controller['data-search-error-title-value']).to eq(I18n.t('search.realtime.error_title'))
        expect(search_controller['data-search-error-message-value']).to eq(I18n.t('search.realtime.error_message'))
        expect(search_controller['data-search-invalid-query-message-value']).to eq(I18n.t('search.realtime.invalid_query_message'))
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
      mobile_bottom_nav = document.at_css('#mobile-bottom-nav .mobile-bottom-nav')
      mobile_receipts_link = document.at_css("#mobile-bottom-nav a[href='#{receipts_path}']")
      mobile_new_receipt_link = document.at_css("#mobile-bottom-nav a[href='#{select_input_method_receipts_path}']")
      mobile_nav_labels = document.css('#mobile-bottom-nav .mobile-bottom-nav-label')
      search_prefixes = header.css('#desktop-search-help [data-search-prefix-param]').map { |node| node['data-search-prefix-param'] }
      tailwind_css = expanded_tailwind_source
      sidebar_full_slot = document.at_css('#desktop-sidebar [data-brand-logo-slot="sidebar-full"]')
      sidebar_narrow_slot = document.at_css('#desktop-sidebar [data-brand-logo-slot="sidebar-narrow"]')
      header_logo_slot = document.at_css('#dashboard-header [data-brand-logo-slot="mobile-header"]')
      sidebar_full_logo = document.at_css('#desktop-sidebar .brand-logo-full')
      sidebar_icon_logo = document.at_css('#desktop-sidebar .brand-logo-icon')
      header_logo = document.at_css('#dashboard-header .mobile-header-brand-logo')

      aggregate_failures do
        expect(document.at_css('#receipts-page-header').text).to include(I18n.t('receipts.index.title'))
        expect(document.at_css('#receipts-page-header').text).to include(I18n.t('dashboard.index.default_subtitle'))
        expect(sidebar_full_slot['class']).to include('hidden')
        expect(sidebar_full_slot['class']).to include('xl:block')
        expect(sidebar_narrow_slot['class']).to include('xl:hidden')
        expect(header_logo_slot['class']).to include('md:hidden')
        expect(header_logo_slot['class']).to include('shrink-0')
        expect(sidebar_full_logo['aria-label']).to eq('Recify')
        expect(sidebar_full_logo.at_css('.brand-logo-text').text).to eq('Recify')
        expect(sidebar_icon_logo['aria-label']).to eq('Recify')
        expect(sidebar_icon_logo['class']).to include('brand-logo-lg')
        expect(sidebar_icon_logo.at_css('.brand-logo-text')).to be_nil
        expect(header_logo['href']).to eq(receipts_path)
        expect(header_logo['class']).to include('brand-logo-compact')
        expect(header_logo.at_css('.brand-logo-text').text).to eq('Recify')
        expect(tailwind_css).to include('.mobile-header-brand-logo .brand-logo-text')
        expect(tailwind_css).to include('@media (width >= 640px), (width <= 359px)')
        expect(document.at_css('#desktop-sidebar').text).to include(I18n.t('dashboard.nav.receipts'))
        expect(document.at_css('#desktop-sidebar').text).to include(I18n.t('dashboard.nav.new_receipt'))
        expect(document.at_css('#mobile-bottom-nav').text).to include(I18n.t('dashboard.nav.mobile_receipts'))
        expect(mobile_bottom_nav['class'].split).to include('mobile-bottom-nav')
        expect(mobile_receipts_link['class'].split).to include('mobile-bottom-nav-link')
        expect(mobile_receipts_link['class'].split).to include('token-text-brand')
        expect(mobile_new_receipt_link['class'].split).to include('token-text-muted')
        expect(mobile_receipts_link['aria-label']).to eq(I18n.t('dashboard.nav.mobile_receipts'))
        expect(mobile_receipts_link['aria-current']).to eq('page')
        expect(mobile_new_receipt_link['aria-label']).to eq(I18n.t('dashboard.nav.mobile_new_receipt'))
        expect(mobile_new_receipt_link['aria-current']).to be_nil
        expect(mobile_receipts_link.at_css('.mobile-bottom-nav-icon')).to be_present
        expect(mobile_receipts_link.at_css('.mobile-bottom-nav-icon')['aria-hidden']).to eq('true')
        expect(mobile_nav_labels.map(&:text)).to include(
          I18n.t('dashboard.nav.mobile_receipts'),
          I18n.t('dashboard.nav.mobile_new_receipt'),
          I18n.t('dashboard.nav.mobile_settings')
        )
        expect(tailwind_css).to include('@media (height <= 700px) and (width <= 380px)')
        expect(tailwind_css).to include('.mobile-bottom-nav-label')
        expect(tailwind_css).to include('clip-path: inset(50%)')
        expect(header.at_css('input[name="q"]')['placeholder']).to eq(I18n.t('dashboard.search.placeholder'))
        expect(header.at_css('input[name="q"]')['data-search-query-input']).to eq('true')
        expect(header.at_css('input[name="q"]')['aria-describedby']).to eq('desktop-search-help')
        expect(header.at_css('#desktop-search-help')['role']).to eq('tooltip')
        expect(header.at_css('#desktop-search-help')['aria-hidden']).to eq('true')
        expect(header.at_css('#desktop-search-help')['class'].split).to include('hidden')
        expect(header.at_css('#desktop-search-help')['class'].split).to include('w-full', 'max-w-none')
        expect(header.at_css('#desktop-search-help')['class'].split).to include('pointer-events-auto')
        expect(header.at_css('#desktop-search-help')['class'].split).to include('overflow-y-auto', 'overscroll-contain')
        expect(header.at_css('#desktop-search-help')['class']).to include('max-h-[calc(100dvh_-_15rem_-_env(safe-area-inset-bottom))]')
        expect(header.at_css('#desktop-search-help')['class']).to include('sm:max-h-[32rem]')
        expect(header.at_css('#desktop-search-help')['class']).not_to include('max-w-[min(28rem')
        expect(header.at_css('#desktop-search-help').text).to include(I18n.t('search.help.title'))
        expect(search_prefixes).to contain_exactly('date>=', 'date<=', 'amount>=', 'amount<=')
        expect(header.at_css('#desktop-search-help').text).to include('数字8桁で YYYY-MM-DD 形式')
        expect(header.at_css('#desktop-search-help').text).to include('そのほかの検索方法')
        expect(header.at_css('#desktop-search-help').text).to include('店舗名・メモ・商品名は通常キーワードで検索できます。')
        expect(header.at_css('#desktop-search-help').text).to include('表示ID（R-XXXXXX）は完全一致で検索できます。')
        expect(header.at_css('#desktop-search-help').text).not_to include('rcpt_')
        expect(header.at_css('#desktop-search-help').text).to include('例: 1000')
        expect(header.at_css('#desktop-search-help').text).to include('例: >=1000, <=5000')
        expect(header.at_css('#desktop-search-help').text).to include('例: 2026-01-01')
        expect(header.at_css('#desktop-search-help').text).to include('例: date:2026-01-01..2026-01-31')
        expect(header.at_css('#desktop-search-help').text).not_to include('status:')
        expect(header.at_css('#desktop-search-help').text).not_to include('payment:')
        expect(header.at_css('#desktop-search-help').text).not_to include('category:')
        expect(header.at_css('#desktop-search-help').text).not_to include('store:')
        expect(header.at_css('#desktop-search-help').text).not_to include('tax_rate:')
        expect(header.at_css('#desktop-search-help').text).not_to include('has:adjustment')
        expect(header.at_css('#desktop-search-help').text).not_to include('needs_review:true')
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
        expect(summary['data-receipt-summary-animate-on-connect-value']).to eq('false')
      end
    end

    it 'スマホ検索結果ではsummaryとページヘッダー登録ボタンだけを非表示にする' do
      get receipts_path(q: my_receipt.store_name)

      document = Nokogiri::HTML(response.body)
      summary = document.at_css('#receipts_search_summary')
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
        io: StringIO.new(png_bytes(width: 120, height: 120, minimum_byte_size: 1.megabyte)),
        filename: 'receipt-storage.jpg',
        content_type: 'image/png'
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
      completed_card = document.at_css("#receipt_#{my_receipt.public_id}")
      processing_card = document.at_css("#receipt_#{processing_receipt.public_id}")

      aggregate_failures do
        expect(completed_card["id"]).to eq("receipt_#{my_receipt.public_id}")
        expect(completed_card["id"]).not_to eq("receipt_#{my_receipt.id}")
        expect(response.body).not_to include("/receipts/#{my_receipt.id}")
        expect(completed_card.text).to include(I18n.t('receipt_cards.fallback.store_name'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.fallback.purchased_at'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.labels.total_amount'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.actions.show'))
        expect(completed_card.text).to include(I18n.t('receipt_cards.actions.edit'))
        expect(processing_card.text).to include(I18n.t('receipt_cards.fallback.processing_store_name'))
        expect(processing_card.text).to include(I18n.t('receipt_cards.fallback.processing_description'))
      end
    end

    it 'processing receipt cardに解析段階を表示する' do
      queued_receipt = create(:receipt, :processing, :with_image, user:, store_name: 'キュー')
      ocr_receipt = create(:receipt, :processing, :with_image, user:, store_name: 'OCR')
      organizing_receipt = create(:receipt, :processing, :with_image, user:, store_name: '整理')
      ai_receipt = create(:receipt, :processing, :with_image, user:, store_name: 'AI')
      finalize_receipt = create(:receipt, :processing, :with_image, user:, store_name: '保存')
      fallback_receipt = create(:receipt, :processing, :with_image, user:, store_name: 'Fallback')
      completed_receipt = create(:receipt, :completed, :with_image, user:, store_name: '完了')
      review_needed_receipt = create(:receipt, :review_needed, :with_image, user:, store_name: '要確認')
      failed_receipt = create(:receipt, :failed, :with_image, user:, store_name: '失敗')

      create(:receipt_analysis_run, receipt: queued_receipt, status: 'queued', stage: 'queued')
      create(
        :receipt_analysis_run,
        receipt: ocr_receipt,
        status: 'running',
        stage: 'ocr',
        ocr_started_at: Time.current
      )
      create(
        :receipt_analysis_run,
        receipt: organizing_receipt,
        status: 'running',
        stage: 'ocr_validation',
        ocr_started_at: 2.seconds.ago,
        ocr_finished_at: Time.current
      )
      create(
        :receipt_analysis_run,
        receipt: ai_receipt,
        status: 'running',
        stage: 'ai',
        ocr_finished_at: 2.seconds.ago,
        ai_started_at: Time.current
      )
      create(
        :receipt_analysis_run,
        receipt: finalize_receipt,
        status: 'running',
        stage: 'finalize',
        ocr_finished_at: 4.seconds.ago,
        ai_started_at: 3.seconds.ago,
        ai_finished_at: 1.second.ago
      )

      get receipts_path

      document = Nokogiri::HTML(response.body)
      step_snapshot = lambda do |receipt|
        document.css("#receipt_#{receipt.public_id} .receipt-processing-step").map do |step|
          classes = step['class'].to_s.split
          {
            node: classes.find { |name| name.match?(/\Areceipt-processing-step-(?:done|active|pending)\z/) },
            interval: classes.find { |name| name.match?(/\Areceipt-processing-interval-(?:completed|active|pending)\z/) },
            aria_current: step['aria-current']
          }
        end
      end

      aggregate_failures do
        expect(document.at_css("#receipt_#{queued_receipt.public_id}").text).to include(I18n.t('receipt_cards.processing_phase.queued.label'))
        expect(document.at_css("#receipt_#{ocr_receipt.public_id}").text).to include(I18n.t('receipt_cards.processing_phase.ocr.label'))
        expect(document.at_css("#receipt_#{organizing_receipt.public_id}").text).to include(I18n.t('receipt_cards.processing_phase.organizing.label'))
        expect(document.at_css("#receipt_#{ai_receipt.public_id}").text).to include(I18n.t('receipt_cards.processing_phase.ai.label'))
        expect(document.at_css("#receipt_#{finalize_receipt.public_id}").text).to include(I18n.t('receipt_cards.processing_phase.finalize.label'))
        expect(document.at_css("#receipt_#{fallback_receipt.public_id}").text).to include(I18n.t('receipt_cards.processing_phase.processing.label'))
        expect(document.css('.receipt-processing-steps').size).to be >= 5
        expect(document.css('.receipt-processing-popover').size).to be >= 5
        expect(document.css('details.receipt-processing-panel')).to be_empty
        expect(document.css('summary.receipt-processing-summary')).to be_empty
        ocr_trigger = document.at_css("#receipt_#{ocr_receipt.public_id} .receipt-processing-trigger")
        ocr_panel = document.at_css("#receipt_#{ocr_receipt.public_id} .receipt-processing-popover-panel")
        expect(ocr_trigger['data-receipt-processing-popover-target']).to eq('trigger')
        expect(ocr_trigger['aria-expanded']).to eq('false')
        expect(ocr_trigger['aria-controls']).to eq(ocr_panel['id'])
        expect(ocr_trigger.at_css('.receipt-processing-trigger-content')).to be_present
        expect(ocr_trigger.text).to include(I18n.t('receipt_cards.processing_phase.click_hint'))
        expect(ocr_trigger.text).to include(I18n.t('receipt_cards.processing_phase.tap_hint'))
        expect(ocr_panel['data-receipt-processing-popover-target']).to eq('panel')
        expect(ocr_panel['role']).to eq('dialog')
        expect(ocr_panel['aria-modal']).to eq('false')
        expect(ocr_panel['aria-labelledby']).to be_present
        expect(ocr_panel.has_attribute?('hidden')).to be(true)
        expect(ocr_panel.at_css("##{ocr_panel['aria-labelledby']}")).to be_present
        expect(ocr_panel.at_css("button[aria-label='#{I18n.t('receipt_cards.processing_phase.close')}']")).to be_present
        expect(document.at_css("#receipt_#{ocr_receipt.public_id}")['class'].split).to include('flex', 'flex-col')
        expect(document.css("#receipt_#{ocr_receipt.public_id} .animate-spin")).to be_empty
        expect(document.at_css("#receipt_#{ocr_receipt.public_id}")['class']).not_to include('animate-pulse')
        expect(document.at_css("#receipt_#{completed_receipt.public_id} .receipt-processing-trigger")).to be_nil
        expect(document.at_css("#receipt_#{review_needed_receipt.public_id} .receipt-processing-trigger")).to be_nil
        expect(document.at_css("#receipt_#{failed_receipt.public_id} .receipt-processing-trigger")).to be_nil
        expect(step_snapshot.call(queued_receipt)).to eq([
          { node: 'receipt-processing-step-active', interval: 'receipt-processing-interval-active', aria_current: 'step' },
          { node: 'receipt-processing-step-pending', interval: 'receipt-processing-interval-pending', aria_current: nil },
          { node: 'receipt-processing-step-pending', interval: 'receipt-processing-interval-pending', aria_current: nil },
          { node: 'receipt-processing-step-pending', interval: nil, aria_current: nil }
        ])
        expect(step_snapshot.call(fallback_receipt)).to eq(step_snapshot.call(queued_receipt))
        expect(step_snapshot.call(ocr_receipt)).to eq([
          { node: 'receipt-processing-step-done', interval: 'receipt-processing-interval-completed', aria_current: nil },
          { node: 'receipt-processing-step-active', interval: 'receipt-processing-interval-active', aria_current: 'step' },
          { node: 'receipt-processing-step-pending', interval: 'receipt-processing-interval-pending', aria_current: nil },
          { node: 'receipt-processing-step-pending', interval: nil, aria_current: nil }
        ])
        expect(step_snapshot.call(organizing_receipt)).to eq(step_snapshot.call(ocr_receipt))
        expect(step_snapshot.call(ai_receipt)).to eq([
          { node: 'receipt-processing-step-done', interval: 'receipt-processing-interval-completed', aria_current: nil },
          { node: 'receipt-processing-step-done', interval: 'receipt-processing-interval-completed', aria_current: nil },
          { node: 'receipt-processing-step-active', interval: 'receipt-processing-interval-active', aria_current: 'step' },
          { node: 'receipt-processing-step-pending', interval: nil, aria_current: nil }
        ])
        expect(step_snapshot.call(finalize_receipt)).to eq([
          { node: 'receipt-processing-step-done', interval: 'receipt-processing-interval-completed', aria_current: nil },
          { node: 'receipt-processing-step-done', interval: 'receipt-processing-interval-completed', aria_current: nil },
          { node: 'receipt-processing-step-done', interval: 'receipt-processing-interval-completed', aria_current: nil },
          { node: 'receipt-processing-step-active', interval: nil, aria_current: 'step' }
        ])
      end
    end

    it 'processing popover controllerは浮動panelを位置補正し開閉状態を復元する設計にする' do
      controller_source = Rails.root.join('app/javascript/controllers/receipt_processing_popover_controller.js').read

      aggregate_failures do
        expect(controller_source).to include('window.sessionStorage')
        expect(controller_source).to include('orphanedPanels')
        expect(controller_source).to include('ORPHANED_PANEL_TTL_MS')
        expect(controller_source).to include('shouldParkOpenPanel')
        expect(controller_source).to include('parkOpenPanel')
        expect(controller_source).to include('takeOrphanedPanel')
        expect(controller_source).to include('adoptOrphanedPanel')
        expect(controller_source).to include('syncPanelAttributes')
        expect(controller_source).to include('preserveVisible')
        expect(controller_source).to include('storage.setItem')
        expect(controller_source).to include('storage.getItem')
        expect(controller_source).to include('aria-expanded')
        expect(controller_source).to include('getBoundingClientRect')
        expect(controller_source).to include('viewportBounds')
        expect(controller_source).to include('window.visualViewport')
        expect(controller_source).to include('fitsViewport')
        expect(controller_source).to include('clamp')
        expect(controller_source).to include('receipt-processing-popover:open')
        expect(controller_source).to include('pointerdown')
        expect(controller_source).to include("event.key !== 'Escape'")
        expect(controller_source).to include('document.body.appendChild')
        expect(controller_source).to include('this.trigger.focus')
        expect(controller_source).to include('event.preventDefault()')
        expect(controller_source).to include('requestAnimationFrame')
        expect(controller_source).to include('window.setTimeout')
      end
    end

    it 'AI開始前のprocessing receipt cardではAI処理中と断定しない' do
      processing_receipt = create(:receipt, :processing, :with_image, user: user)
      create(
        :receipt_analysis_run,
        receipt: processing_receipt,
        status: 'running',
        stage: 'ai',
        ocr_finished_at: Time.current,
        ai_started_at: nil
      )

      get receipts_path

      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{processing_receipt.public_id}")

      aggregate_failures do
        expect(card.text).to include(I18n.t('receipt_cards.processing_phase.organizing.label'))
        expect(card.text).not_to include(I18n.t('receipt_cards.processing_phase.ai.label'))
      end
    end

    it 'receipt cardは長い店舗名でステータスを押し出さない構造にする' do
      my_receipt.update!(store_name: 'とても長い店舗名' * 12)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{my_receipt.public_id}")
      header_row = card.at_css('.flex.min-w-0.items-start.justify-between.gap-4')
      text_group = header_row.at_css('.flex.flex-1.items-start.gap-3.min-w-0')
      status_badge = header_row.css('span').find { |node| node.text.strip == my_receipt.status_label }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(header_row).to be_present
        expect(text_group).to be_present
        expect(status_badge['class']).to include('shrink-0')
        expect(card.at_css('h2')['class']).to include('truncate')
      end
    end

    it 'receipt cardはnil合計を未設定、明示0合計を¥0として表示する' do
      nil_amount_receipt = create(:receipt, user: user, store_name: '未設定金額', total_amount: 1_000, status: 'completed')
      nil_amount_receipt.update_columns(total_amount: nil)
      zero_amount_receipt = create(:receipt, user: user, store_name: '0円金額', total_amount: 0, status: 'completed')

      get receipts_path

      document = Nokogiri::HTML(response.body)
      nil_amount_card = document.at_css("#receipt_#{nil_amount_receipt.public_id}")
      zero_amount_card = document.at_css("#receipt_#{zero_amount_receipt.public_id}")

      aggregate_failures do
        expect(nil_amount_card.text).to include(I18n.t('receipts.common.unset'))
        expect(nil_amount_card.text).not_to include('¥0')
        expect(zero_amount_card.text).to include('¥0')
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
      search_prefixes = mobile_panel.css('#mobile-search-help [data-search-prefix-param]').map { |node| node['data-search-prefix-param'] }

      aggregate_failures do
        expect(mobile_panel).to be_present
        expect(mobile_panel.ancestors).not_to include(header)
        expect(header.at_css('.search-panel-mobile')).to be_nil
        expect(mobile_panel.at_css('input[name="q"]')['value']).to eq(my_receipt.store_name)
        expect(mobile_panel.at_css('input[name="q"]')['data-search-query-input']).to eq('true')
        expect(mobile_panel.at_css('input[name="q"]')['aria-describedby']).to eq('mobile-search-help')
        expect(mobile_panel.at_css('#mobile-search-help').text).to include(I18n.t('search.help.title'))
        expect(mobile_panel.at_css('#mobile-search-help')['class'].split).to include('hidden')
        expect(mobile_panel.at_css('#mobile-search-help')['class'].split).to include('w-full', 'max-w-none')
        expect(mobile_panel.at_css('#mobile-search-help')['class'].split).to include('pointer-events-auto')
        expect(mobile_panel.at_css('#mobile-search-help')['class'].split).to include('overflow-y-auto', 'overscroll-contain')
        expect(mobile_panel.at_css('#mobile-search-help')['class']).to include('max-h-[calc(100dvh_-_15rem_-_env(safe-area-inset-bottom))]')
        expect(mobile_panel.at_css('#mobile-search-help')['class']).to include('sm:max-h-[32rem]')
        expect(mobile_panel.at_css('#mobile-search-help')['class']).not_to include('max-w-[min(28rem')
        expect(search_prefixes).to contain_exactly('date>=', 'date<=', 'amount>=', 'amount<=')
        expect(mobile_panel.at_css('#mobile-search-help').text).to include('そのほかの検索方法')
        expect(mobile_panel.at_css('#mobile-search-help').text).to include('表示ID（R-XXXXXX）は完全一致で検索できます。')
        expect(mobile_panel.at_css('#mobile-search-help').text).not_to include('rcpt_')
        expect(mobile_panel.at_css('#mobile-search-help').text).to include('例: date:2026-01-01..2026-01-31')
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
        expect(card_ids.index("receipt_#{newer_receipt.public_id}")).to be < card_ids.index("receipt_#{older_receipt.public_id}")
        expect(document.at_css('#receipts-page-header').text).to include('3件')
        expect(document.at_css('#receipts_search_summary').text).to include('¥300')
      end
    end

    it 'defaultでは作成日時の新しい順で表示する' do
      older_receipt = create(:receipt, user: user, store_name: '古い順序', total_amount: 100, status: 'completed', created_at: 2.days.ago)
      newer_receipt = create(:receipt, user: user, store_name: '新しい順序', total_amount: 200, status: 'completed', created_at: 1.hour.ago)

      get receipts_path

      card_ids = receipt_card_ids(Nokogiri::HTML(response.body))

      expect(card_ids.index("receipt_#{newer_receipt.public_id}")).to be < card_ids.index("receipt_#{older_receipt.public_id}")
    end

    it 'oldest sortでは作成日時の古い順で表示する' do
      older_receipt = create(:receipt, user: user, store_name: '古いsort', total_amount: 100, status: 'completed', created_at: 2.days.ago)
      newer_receipt = create(:receipt, user: user, store_name: '新しいsort', total_amount: 200, status: 'completed', created_at: 1.hour.ago)

      get receipts_path(sort: 'oldest')

      document = Nokogiri::HTML(response.body)
      card_ids = receipt_card_ids(document)

      aggregate_failures do
        expect(card_ids.index("receipt_#{older_receipt.public_id}")).to be < card_ids.index("receipt_#{newer_receipt.public_id}")
        expect(selected_receipt_index_control(document, 'sort')).to eq('oldest')
      end
    end

    it '金額sortではnil金額を最後にして並び替える' do
      low_receipt = create(:receipt, user: user, store_name: '金額小', total_amount: 100, status: 'completed')
      high_receipt = create(:receipt, user: user, store_name: '金額大', total_amount: 5_000, status: 'completed')
      nil_amount_receipt = create(:receipt, user: user, store_name: '金額nil', total_amount: 300, status: 'completed')
      nil_amount_receipt.update_columns(total_amount: nil)

      get receipts_path(sort: 'amount_desc')
      desc_card_ids = receipt_card_ids(Nokogiri::HTML(response.body))

      get receipts_path(sort: 'amount_asc')
      asc_card_ids = receipt_card_ids(Nokogiri::HTML(response.body))

      aggregate_failures do
        expect(desc_card_ids.index("receipt_#{high_receipt.public_id}")).to be < desc_card_ids.index("receipt_#{low_receipt.public_id}")
        expect(desc_card_ids.index("receipt_#{low_receipt.public_id}")).to be < desc_card_ids.index("receipt_#{nil_amount_receipt.public_id}")
        expect(asc_card_ids.index("receipt_#{low_receipt.public_id}")).to be < asc_card_ids.index("receipt_#{high_receipt.public_id}")
        expect(asc_card_ids.index("receipt_#{high_receipt.public_id}")).to be < asc_card_ids.index("receipt_#{nil_amount_receipt.public_id}")
      end
    end

    it '店名sortでは空文字とnilを最後寄りにして並び替える' do
      alpha_receipt = create(:receipt, user: user, store_name: 'Alpha Store', total_amount: 100, status: 'completed')
      zebra_receipt = create(:receipt, user: user, store_name: 'Zebra Store', total_amount: 200, status: 'completed')
      blank_store_receipt = create(:receipt, user: user, store_name: 'Blank Store', total_amount: 300, status: 'completed')
      nil_store_receipt = create(:receipt, user: user, store_name: 'Nil Store', total_amount: 400, status: 'completed')
      blank_store_receipt.update_columns(store_name: '')
      nil_store_receipt.update_columns(store_name: nil)

      get receipts_path(sort: 'store_name')

      card_ids = receipt_card_ids(Nokogiri::HTML(response.body))

      aggregate_failures do
        expect(card_ids.index("receipt_#{alpha_receipt.public_id}")).to be < card_ids.index("receipt_#{zebra_receipt.public_id}")
        expect(card_ids.index("receipt_#{zebra_receipt.public_id}")).to be < card_ids.index("receipt_#{blank_store_receipt.public_id}")
        expect(card_ids.index("receipt_#{blank_store_receipt.public_id}")).to be < card_ids.index("receipt_#{nil_store_receipt.public_id}")
      end
    end

    it 'updated sortでは更新日時の新しい順で表示する' do
      older_updated_receipt = create(:receipt, user: user, store_name: '古い更新', total_amount: 100, status: 'completed')
      newer_updated_receipt = create(:receipt, user: user, store_name: '新しい更新', total_amount: 200, status: 'completed')
      older_updated_receipt.update_columns(updated_at: 2.days.ago)
      newer_updated_receipt.update_columns(updated_at: 1.hour.ago)

      get receipts_path(sort: 'updated')

      card_ids = receipt_card_ids(Nokogiri::HTML(response.body))

      expect(card_ids.index("receipt_#{newer_updated_receipt.public_id}")).to be < card_ids.index("receipt_#{older_updated_receipt.public_id}")
    end

    it 'review_priority sortでは要確認を優先して表示する' do
      completed_receipt = create(:receipt, user: user, store_name: '完了優先比較', total_amount: 100, status: 'completed', created_at: 1.hour.ago)
      review_receipt = create(:receipt, :review_needed, user: user, store_name: '要確認優先比較', total_amount: 200, created_at: 2.days.ago)

      get receipts_path(sort: 'review_priority')

      document = Nokogiri::HTML(response.body)
      card_ids = receipt_card_ids(document)

      aggregate_failures do
        expect(card_ids.index("receipt_#{review_receipt.public_id}")).to be < card_ids.index("receipt_#{completed_receipt.public_id}")
        expect(selected_receipt_index_control(document, 'sort')).to eq('review_priority')
      end
    end

    it 'per_page 20/50/100で表示件数を切り替える' do
      create_list(:receipt, 105, user: user, status: 'completed')

      get receipts_path
      default_document = Nokogiri::HTML(response.body)

      get receipts_path(per_page: 50)
      fifty_document = Nokogiri::HTML(response.body)

      get receipts_path(per_page: 100)
      hundred_document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(receipt_card_ids(default_document).size).to eq(20)
        expect(selected_receipt_index_control(default_document, 'per_page')).to eq('20')
        expect(receipt_card_ids(fifty_document).size).to eq(50)
        expect(selected_receipt_index_control(fifty_document, 'per_page')).to eq('50')
        expect(receipt_card_ids(hundred_document).size).to eq(100)
        expect(selected_receipt_index_control(hundred_document, 'per_page')).to eq('100')
      end
    end

    it '不正なsort/per_pageはdefaultへfallbackしpaginationへ残さない' do
      create_list(:receipt, 21, user: user, status: 'completed')

      get receipts_path(sort: 'created_at desc', per_page: '999', page: 2)

      document = Nokogiri::HTML(response.body)
      pagination_urls = document.css('nav[aria-label] a').map { |node| node['href'] }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(selected_receipt_index_control(document, 'sort')).to eq('newest')
        expect(selected_receipt_index_control(document, 'per_page')).to eq('20')
        expect(pagination_urls.join(' ')).not_to include('created_at')
        expect(pagination_urls.join(' ')).not_to include('per_page=999')
      end
    end

    it '検索フォーム送信時にsort/per_pageを維持するhidden fieldを描画する' do
      get receipts_path(q: my_receipt.store_name, sort: 'oldest', per_page: 50)

      document = Nokogiri::HTML(response.body)
      search_forms = document.css("form[action='#{receipts_path}']")

      aggregate_failures do
        expect(search_forms.any? { |form| form.at_css("input[name='sort'][value='oldest']").present? }).to be(true)
        expect(search_forms.any? { |form| form.at_css("input[name='per_page'][value='50']").present? }).to be(true)
        expect(receipt_index_controls(document).at_css("input[name='q'][value='#{my_receipt.store_name}']")).to be_present
      end
    end

    it 'paginationリンクではq/sort/per_pageを維持する' do
      create_list(:receipt, 55, user: user, store_name: '維持ストア', total_amount: 100, status: 'completed')

      get receipts_path(q: '維持ストア', sort: 'oldest', per_page: 50)

      document = Nokogiri::HTML(response.body)
      pagination_urls = document.css('nav[aria-label] a').map { |node| node['href'] }

      expect(pagination_urls).to include(receipts_path(q: '維持ストア', sort: 'oldest', per_page: 50, page: 2))
    end

    it 'sort/per_page変更フォームにはpage hiddenを描画しない' do
      create_list(:receipt, 55, user: user, store_name: 'ページ維持なし', total_amount: 100, status: 'completed')

      get receipts_path(q: 'ページ維持なし', sort: 'oldest', per_page: 50, page: 2)

      document = Nokogiri::HTML(response.body)
      controls = receipt_index_controls(document)

      aggregate_failures do
        expect(controls.at_css("input[name='q'][value='ページ維持なし']")).to be_present
        expect(controls.at_css("input[name='page']")).to be_nil
      end
    end

    it 'default以外のsort/per_pageではcreate prepend専用streamを購読しない' do
      get receipts_path(sort: 'oldest')
      sorted_document = Nokogiri::HTML(response.body)

      get receipts_path(per_page: 50)
      per_page_document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(sorted_document.css('turbo-cable-stream-source').size).to eq(2)
        expect(per_page_document.css('turbo-cable-stream-source').size).to eq(2)
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
      card = document.at_css("#receipt_#{failed_receipt.public_id}")

      aggregate_failures do
        expect(card.at_css("a[href='#{receipt_path(failed_receipt, from: 'index')}']")).to be_present
        expect(card.at_css("a[href='#{edit_receipt_path(failed_receipt, from: 'index')}']")).to be_present
      end
    end

    it 'review_needed receipt の一覧カードから詳細/編集へ進める' do
      review_receipt = create(:receipt, :review_needed, user: user)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{review_receipt.public_id}")

      aggregate_failures do
        expect(card.at_css("a[href='#{receipt_path(review_receipt, from: 'index')}']")).to be_present
        expect(card.at_css("a[href='#{edit_receipt_path(review_receipt, from: 'index')}']")).to be_present
      end
    end

    it 'processing receipt の一覧カードは詳細/編集リンクを無効表示にする' do
      processing_receipt = create(:receipt, :processing, :with_image, user: user)

      get receipts_path

      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{processing_receipt.public_id}")

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

  describe 'GET /receipts/processing_cards' do
    let!(:processing_receipt) do
      create(:receipt, :processing, :with_image, user:, store_name: '処理中レシート')
    end
    let!(:processing_run) do
      create(
        :receipt_analysis_run,
        receipt: processing_receipt,
        status: 'running',
        stage: 'ocr',
        ocr_started_at: Time.current
      )
    end
    let!(:terminal_receipt) do
      create(:receipt, :review_needed, user:, store_name: '確認対象レシート')
    end

    it '現在ユーザーの複数カードを最新状態のTurbo Streamで返す' do
      get processing_cards_receipts_path,
          params: { public_ids: [ processing_receipt.public_id, terminal_receipt.public_id ] },
          headers: { 'ACCEPT' => Mime[:turbo_stream].to_s }

      document = Nokogiri::HTML.fragment(response.body)
      processing_stream = document.at_css(%(turbo-stream[action="replace"][target="#{processing_receipt.dom_target_id}"]))
      terminal_stream = document.at_css(%(turbo-stream[action="replace"][target="#{terminal_receipt.dom_target_id}"]))
      processing_card = processing_stream.at_css("##{processing_receipt.dom_target_id}")
      terminal_card = terminal_stream.at_css("##{terminal_receipt.dom_target_id}")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.media_type).to eq(Mime[:turbo_stream].to_s)
        expect(response.headers['Cache-Control']).to eq('no-store')
        expect(processing_card['data-receipt-processing-sync-target']).to eq('card')
        expect(processing_card['data-receipt-card-public-id']).to eq(processing_receipt.public_id)
        expect(processing_card['data-receipt-card-phase']).to eq('ocr')
        expect(processing_card['data-receipt-card-state-revision'].to_i).to be_positive
        expect(processing_card['data-receipt-card-terminal']).to eq('false')
        expect(terminal_card['data-receipt-card-terminal']).to eq('true')
        expect(terminal_card['data-receipt-processing-sync-target']).to be_nil
      end
    end

    it '他人のreceipt内容を返さず対象DOMのremoveだけを返す' do
      other_receipt = create(
        :receipt,
        :processing,
        :with_image,
        user: create(:user),
        store_name: '他人の非公開店舗名'
      )

      get processing_cards_receipts_path,
          params: { public_ids: [ other_receipt.public_id ] },
          headers: { 'ACCEPT' => Mime[:turbo_stream].to_s }

      document = Nokogiri::HTML.fragment(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css(%(turbo-stream[action="remove"][target="#{other_receipt.dom_target_id}"]))).to be_present
        expect(response.body).not_to include('他人の非公開店舗名')
      end
    end

    it 'カードのstate revisionが変わっていなければDOMを置換しない' do
      presenter = Receipts::ProcessingPhasePresenter.new(
        receipt: processing_receipt,
        analysis_run: processing_run
      )

      get processing_cards_receipts_path,
          params: {
            public_ids: [ processing_receipt.public_id ],
            state_revisions: [ presenter.state_revision.to_s ]
          },
          headers: { 'ACCEPT' => Mime[:turbo_stream].to_s }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.media_type).to eq(Mime[:turbo_stream].to_s)
        expect(response.body).not_to include('<turbo-stream')
      end
    end

    it '未ログインでは利用できない' do
      sign_out user

      get processing_cards_receipts_path,
          params: { public_ids: [ processing_receipt.public_id ] },
          headers: { 'ACCEPT' => Mime[:turbo_stream].to_s }

      expect(response).to redirect_to(new_user_session_path)
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
        expect(form['data-receipt-form-unset-label-value']).to eq(I18n.t('receipts.common.not_available'))
        expect(form['data-receipt-form-multiple-tax-rates-label-value']).to eq(I18n.t('receipts.common.multiple_tax_rates'))
      end
    end

    it 'SystemSettingsの金額上限をform data属性と入力maxへ渡す' do
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(320))
      create(:system_setting, key: 'limits.receipt_item_line_total_max', value: SystemSettings.stored_value(420))
      create(:system_setting, key: 'limits.receipt_tax_amount_max', value: SystemSettings.stored_value(210))
      create(:system_setting, key: 'limits.receipt_adjustment_amount_max', value: SystemSettings.stored_value(220))
      create(:system_setting, key: 'limits.receipt_payment_amount_max', value: SystemSettings.stored_value(430))
      create(:system_setting, key: 'limits.receipt_total_amount_max', value: SystemSettings.stored_value(500))

      get new_receipt_path

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')
      item_row = document.at_css('[data-receipt-form-target="itemRow"]')
      adjustment_template = Nokogiri::HTML.fragment(document.at_css('template[data-receipt-form-target="adjustmentTemplate"]')&.inner_html.to_s)
      payment_template = Nokogiri::HTML.fragment(document.at_css('template[data-receipt-form-target="paymentTemplate"]')&.inner_html.to_s)

      aggregate_failures do
        expect(form['data-receipt-form-receipt-total-amount-max-value']).to eq('500')
        expect(form['data-receipt-form-receipt-item-price-max-value']).to eq('320')
        expect(form['data-receipt-form-receipt-item-line-total-max-value']).to eq('420')
        expect(form['data-receipt-form-receipt-tax-amount-max-value']).to eq('210')
        expect(form['data-receipt-form-receipt-adjustment-amount-max-value']).to eq('220')
        expect(form['data-receipt-form-receipt-payment-amount-max-value']).to eq('430')
        expect(document.at_css('[data-receipt-form-target="priceInput"]')['max']).to eq('320')
        expect(adjustment_template.at_css('[data-receipt-form-target="adjustmentAmountInput"]')['max']).to eq('220')
        expect(payment_template.at_css('[data-receipt-form-target="paymentAmountInput"]')['max']).to eq('430')
        expect(item_row.at_css('[data-receipt-form-target="quantityInput"]')['inputmode']).to eq('numeric')
        expect(item_row.at_css('[data-receipt-form-target="priceInput"]')['inputmode']).to eq('numeric')
        expect(item_row.at_css('[data-receipt-form-target="discountRateInput"]')['inputmode']).to eq('decimal')
        expect(item_row.at_css('[data-receipt-form-target="taxRateInput"]')['inputmode']).to eq('decimal')
        expect(adjustment_template.at_css('[data-receipt-form-target="adjustmentAmountInput"]')['inputmode']).to eq('numeric')
        expect(adjustment_template.at_css('[data-receipt-form-target="adjustmentTaxRateInput"]')['inputmode']).to eq('decimal')
        expect(payment_template.at_css('[data-receipt-form-target="paymentAmountInput"]')['inputmode']).to eq('numeric')
      end
    end

    it 'receipt form controllerの金額clampは固定値ではなくdata属性の上限値を使う' do
      controller_source = Rails.root.join('app/javascript/controllers/receipt_form_controller.js').read

      expect(controller_source).not_to match(/clampNumber\([^\n]+999999999/)
    end

    it 'current_userのrounding modeをform data属性へ渡す' do
      user.update!(tax_rounding_mode: 'ceil', discount_rounding_mode: 'floor')

      get new_receipt_path

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(form['data-receipt-form-rounding-mode-value']).to eq('ceil')
        expect(form['data-receipt-form-discount-rounding-mode-value']).to eq('floor')
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
        expect(document.at_css('[data-receipt-form-target="totalAmount"]').text.strip).to eq(I18n.t('receipts.common.unset'))
        expect(document.at_css('[data-receipt-form-target="subtotalAmount"]').text.strip).to eq(I18n.t('receipts.common.not_available'))
        expect(document.at_css('[data-receipt-form-target="taxAmount"]').text.strip).to eq(I18n.t('receipts.common.not_available'))
        expect(document.at_css('[data-receipt-form-target="taxRateSummary"]').text.strip).to eq(I18n.t('receipts.common.not_available'))
        expect(item_row.at_css('[data-receipt-form-target="lineTotalDisplay"]').text.strip).to eq(I18n.t('receipts.common.not_available'))
        expect(template.at_css('[data-receipt-form-target="quantityInput"]')['value']).to eq('1')
        expect(template.at_css('[data-receipt-form-target="priceInput"]')['value'].to_s).to eq('')
        expect(template.at_css('[data-receipt-form-target="discountRateInput"]')['value'].to_s).to eq('')
        expect(template.at_css('[data-receipt-form-target="taxRateInput"]')['value'].to_s).to eq('')
      end
    end

    it '調整行テンプレートを明細行と同じ折りたたみ構造で描画する' do
      get new_receipt_path

      document = Nokogiri::HTML(response.body)
      template_html = document.at_css('template[data-receipt-form-target="adjustmentTemplate"]')&.inner_html.to_s
      template = Nokogiri::HTML.fragment(template_html)
      adjustment_row = template.at_css('[data-receipt-form-target="adjustmentRow"]')
      details_panel = adjustment_row.at_css('[data-receipt-form-target="adjustmentDetailsPanel"]')
      amount_input = adjustment_row.at_css('[data-receipt-form-target="adjustmentAmountInput"]')
      tax_rate_input = details_panel.at_css('[data-receipt-form-target="adjustmentTaxRateInput"]')
      sign_select = details_panel.at_css('[data-receipt-form-target="adjustmentSignSelect"]')
      sign_hidden = adjustment_row.at_css('input[type="hidden"][data-receipt-form-target="adjustmentSignInput"]')
      mobile_detail_fields = adjustment_row.css('.receipt-form-adjustment-mobile-detail-field')
      swipe_wrapper = adjustment_row.ancestors.find { |node| node['data-controller'].to_s.include?('swipe-action') }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(adjustment_row['class']).to include('receipt-form-adjustment-row')
        expect(swipe_wrapper).to be_present
        expect(swipe_wrapper.at_css('[data-swipe-action-target="foreground"]')).to be_present
        expect(swipe_wrapper.at_css('.swipe-action-background [data-action*="receipt-form#removeAdjustment"][data-swipe-action-target="action"]')).to be_present
        expect(adjustment_row.at_css('[data-receipt-form-target="adjustmentDetailsToggle"]')).to be_present
        expect(adjustment_row.at_css('[data-receipt-form-target="adjustmentDetailsIcon"]').text).to include('expand_more')
        expect(adjustment_row.at_css('.receipt-form-adjustment-mobile-summary')).to be_present
        expect(mobile_detail_fields.size).to be >= 2
        expect(details_panel['class']).to include('collapsible-grid')
        expect(amount_input['class']).to include('field-stepper-input')
        expect(amount_input['class']).to include('text-center')
        expect(tax_rate_input['class']).to include('field-stepper-input')
        expect(tax_rate_input['class']).to include('text-center')
        expect(sign_select).to be_present
        expect(sign_hidden).to be_present
        expect(sign_hidden['value']).to eq('surcharge')
        expect(adjustment_row['data-receipt-form-adjustment-effect']).to eq('purchase_adjustment')
        expect(template.text).not_to include('種別に応じて加算または減算を自動設定します')
        expect(template.text).not_to include('ポイント利用は支払調整として扱い')
        expect(response.body).not_to include('種別に応じて加算または減算を自動設定します')
        expect(response.body).not_to include('ポイント利用は支払調整として扱い')
      end
    end

    it 'mobile detailのfocus ringとdesktop hover重なり対策CSSを持つ' do
      css = expanded_tailwind_source

      aggregate_failures do
        expect(css).to include('.receipt-form-item-details-open .collapsible-grid-inner')
        expect(css).to include('.receipt-form-adjustment-details-open .collapsible-grid-inner')
        expect(css).to include('.swipe-action:hover')
        expect(css).to include('.swipe-action:focus-within')
        expect(css).to include('z-index: 30')
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
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

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
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

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

    it 'OCR provider詳細は登録方法選択画面に表示しない' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return(
        state: 'down',
        last_error_code: 'external_service_quota_exceeded',
        last_error_detail: {
          provider_error_code: 'QuotaExceeded',
          provider_message_safe: 'F0 quota exceeded for [FILTERED]',
          request_id: 'azure-request-id'
        }
      )
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get select_input_method_receipts_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(response.body).not_to include('external_service_quota_exceeded')
        expect(response.body).not_to include('QuotaExceeded')
        expect(response.body).not_to include('F0 quota exceeded')
        expect(response.body).not_to include('azure-request-id')
      end
    end

    it 'AI down時は画像アップロード導線をdisabledにせず注意を表示する' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'down' })

      get select_input_method_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('AI補完は一時停止中です。OCR結果をもとに確認・修正できます。')
        expect(document.at_css('a[href="' + new_upload_receipts_path + '"]')).to be_present
        expect(document.at_css('[data-service-disabled="ocr"]')).to be_nil
      end
    end

    it 'SystemSettingsでOCR停止中は画像アップロード導線をdisabled表示する' do
      create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))

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

    it 'SystemSettingsでOCRとAIが停止中でもOCR結果前提のAI停止noticeは表示しない' do
      create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))
      create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))

      get select_input_method_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(document.at_css('[data-service-notice-key="ai_down"]')['class']).to include('hidden')
        expect(document.at_css('[data-service-disabled="ocr"]')).to be_present
      end
    end

    it 'SystemSettingsでAI停止中は画像アップロード導線を維持して注意を表示する' do
      create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))

      get select_input_method_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.select_input_method.ai_down'))
        expect(document.at_css('a[href="' + new_upload_receipts_path + '"]')).to be_present
        expect(document.at_css('[data-service-disabled="ocr"]')).to be_nil
      end
    end
  end

  describe 'GET /receipts/new_upload' do
    it 'アップロード画面の主要文言をlocale経由で描画しJS用文言をdata属性へ渡す' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)
      upload_root = document.at_css('[data-controller~="receipt-upload"]')
      upload_layout = document.at_css('[data-receipt-upload-layout]')
      upload_column = document.at_css('[data-receipt-upload-column]')
      guidance_panel = document.at_css('[data-receipt-upload-guidance]')
      storage_meter = guidance_panel&.at_css('[data-storage-usage-meter]')
      camera_input = document.at_css('input[type="file"][name="receipt[image]"]')
      library_input = document.at_css('input[type="file"][name="receipt[images][]"]')
      preview_controls = document.at_css('[data-receipt-upload-target="previewControls"]')
      preview_previous_button = document.at_css('[data-receipt-upload-target="previewPreviousButton"]')
      preview_next_button = document.at_css('[data-receipt-upload-target="previewNextButton"]')
      preview_counter = document.at_css('[data-receipt-upload-target="previewCounter"]')
      preview_current_file_name = document.at_css('[data-receipt-upload-target="previewCurrentFileName"]')
      mobile_footer = document.css('footer').find { |node| node.text.include?(I18n.t('receipts.new_upload.queued_hint')) }
      expected_accept = %w[
        image/jpeg image/png image/bmp image/tiff image/heif image/heic
        .jpg .jpeg .png .bmp .tif .tiff .heif .heic
      ].join(',')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('receipts.new_upload.title'))
        expect(response.body).to include(I18n.t('receipts.new_upload.buttons.upload'))
        expect(response.body).to include('max-w-3xl lg:max-w-7xl')
        expect(upload_layout['class']).to include('lg:grid')
        expect(upload_layout['class']).to include('lg:grid-cols-3')
        expect(upload_layout['class']).to include('lg:space-y-0')
        expect(upload_column['class']).to include('lg:col-span-2')
        expect(guidance_panel['class']).to include('hidden')
        expect(guidance_panel['class']).to include('lg:block')
        expect(guidance_panel.text).to include(I18n.t('receipts.new_upload.guidance.flow_title'))
        expect(guidance_panel.text).to include(I18n.t('receipts.new_upload.guidance.formats_title'))
        expect(guidance_panel.text).to include(I18n.t('receipts.new_upload.guidance.tips_title'))
        expect(guidance_panel.text).to include(I18n.t('receipts.new_upload.guidance.manual_link'))
        expect(guidance_panel.text).to include(I18n.t('receipts.new_upload.guidance.storage_title'))
        expect(guidance_panel.text).not_to include('PDF')
        expect(guidance_panel.text).not_to include('45 / 100')
        expect(guidance_panel.text).not_to include('10MB')
        expect(storage_meter).to be_present
        expect(mobile_footer).to be_present
        expect(mobile_footer['class']).to include('md:hidden')
        expect(mobile_footer.text).to include(I18n.t('receipts.new_upload.back'))
        expect(upload_root['data-receipt-upload-invalid-image-message-value']).to eq(I18n.t('receipts.new_upload.js.invalid_image'))
        expect(upload_root['data-receipt-upload-empty-file-message-value']).to eq(I18n.t('receipts.new_upload.js.empty_file'))
        expect(upload_root['data-receipt-upload-storage-used-bytes-value']).to eq(user.storage_used_bytes.to_s)
        expect(upload_root['data-receipt-upload-storage-limit-bytes-value']).to eq(user.storage_limit_bytes.to_s)
        expect(upload_root['data-receipt-upload-quota-exceeded-message-value']).to eq(I18n.t('receipts.new_upload.js.quota_exceeded'))
        expect(upload_root['data-receipt-upload-max-file-count-value']).to eq(Receipts::Uploads.max_files.to_s)
        expect(upload_root['data-receipt-upload-max-file-count-message-value']).to eq(I18n.t('receipts.new_upload.js.max_files', max: Receipts::Uploads.max_files))
        expect(upload_root['data-receipt-upload-selected-files-message-value']).to eq(I18n.t('receipts.new_upload.js.selected_files'))
        expect(upload_root['data-receipt-upload-preview-counter-message-value']).to eq(I18n.t('receipts.new_upload.js.preview_counter'))
        expect(response.body).to include(I18n.t('receipts.new_upload.multiple_hint', max: Receipts::Uploads.max_files))
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

    it '一括アップロード件数上限の設定値をUIへ渡す' do
      create(:system_setting, key: 'limits.batch_upload_max_files', value: SystemSettings.stored_value(10))
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)
      upload_root = document.at_css('[data-controller~="receipt-upload"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(upload_root['data-receipt-upload-max-file-count-value']).to eq('10')
        expect(upload_root['data-receipt-upload-max-file-count-message-value']).to eq(I18n.t('receipts.new_upload.js.max_files', max: 10))
        expect(response.body).to include(I18n.t('receipts.new_upload.multiple_hint', max: 10))
      end
    end

    it 'OCR down時は警告を表示しアップロード操作をdisabledにする' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

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

    it 'OCR down / AI down時はアップロード画面でOCR結果前提のAI停止noticeを表示しない' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'down' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(document.at_css('[data-service-notice-key="ai_down"]')['class']).to include('hidden')
        expect(document.at_css('[data-receipt-upload-ocr-available-value="false"]')).to be_present
      end
    end

    it 'OCR down / AI degraded時もアップロード画面でAI degraded noticeを表示しない' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'degraded' })

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(document.at_css('[data-service-notice-key="ai_degraded"]')['class']).to include('hidden')
        expect(document.at_css('[data-receipt-upload-ocr-available-value="false"]')).to be_present
      end
    end

    it 'AI provider詳細はアップロード画面に表示せずOCR-only説明に丸める' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return(
        state: 'down',
        last_error_code: 'ai_rate_limited',
        last_error_detail: {
          provider_error_code: 'rate_limit_exceeded',
          provider_message_safe: 'rate limit for [FILTERED]',
          request_id: 'req_ai'
        }
      )

      get new_upload_receipts_path

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.new_upload.ai_down'))
        expect(response.body).not_to include('ai_rate_limited')
        expect(response.body).not_to include('rate_limit_exceeded')
        expect(response.body).not_to include('rate limit for')
        expect(response.body).not_to include('req_ai')
      end
    end

    it 'SystemSettingsでAI停止中はアップロード操作を維持してAI停止noticeを表示する' do
      create(:system_setting, key: 'operations.ai_enabled', value: SystemSettings.stored_value(false))

      get new_upload_receipts_path

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.new_upload.ai_down'))
        expect(document.at_css('[data-service-notice-key="ai_down"]')['class']).not_to include('hidden')
        expect(document.at_css('[data-receipt-upload-ocr-available-value="true"]')).to be_present
        expect(document.css('button[disabled]').map(&:text).join).not_to include('カメラを起動')
        expect(document.css('button[disabled]').map(&:text).join).not_to include('ファイルを選択')
      end
    end

    it 'OCR degraded時はアップロード可能なまま注意を表示する' do
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'degraded' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

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
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'down' })

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
    before do
      allow(ReceiptOcrJob).to receive(:perform_later)
    end

    it '単一camera uploadはsource: uploadのrunを作成しrun_id付きOCR jobをenqueueする' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)
        .and change(ReceiptAnalysisRun, :count).by(1)

      receipt = Receipt.order(:id).last
      run = receipt.receipt_analysis_runs.sole

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt).to be_processing
        expect(receipt.image).to be_attached
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.review_reasons).to eq([])
        expect(run.source).to eq('upload')
        expect(run.requested_by_user).to eq(user)
        expect(run.status).to eq('queued')
        expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
      end
    end

    it '単一uploadのenqueue失敗時はprocessingを残さず失敗状態を表示する' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptOcrJob).to receive(:perform_later).and_raise(StandardError, 'queue unavailable')

      post upload_receipts_path, params: { receipt: { image: uploaded_image } }

      receipt = Receipt.order(:id).last
      run = receipt.receipt_analysis_runs.sole

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(flash[:alert]).to eq(I18n.t('flash.receipts.analysis_enqueue_failed'))
        expect(receipt.reload).to have_attributes(
          status: 'failed',
          processing_error_code: 'analysis_enqueue_failed'
        )
        expect(run.reload).to have_attributes(
          status: 'failed',
          error_stage: 'enqueue',
          error_code: 'analysis_enqueue_failed'
        )
      end
    end

    it 'runtime config取得失敗時はrunとjobを作らず失敗状態を表示する' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:runtime_config_snapshot)
        .and_raise(ExternalServices::RuntimeConfigUnavailableError)

      post upload_receipts_path, params: { receipt: { image: uploaded_image } }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(flash[:alert]).to eq(I18n.t('flash.receipts.analysis_enqueue_failed'))
        expect(receipt.reload).to have_attributes(
          status: 'failed',
          processing_error_code: 'runtime_config_unavailable'
        )
        expect(receipt.receipt_analysis_runs).to be_empty
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '単一uploadはuserの画像保持設定をsnapshotし、解析完了前はpurge候補化しない' do
      user.update!(keep_receipt_images: false)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      post upload_receipts_path, params: { receipt: { image: uploaded_image } }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.keep_image).to be(false)
        expect(receipt.image_purge_eligible_at).to be_nil
      end
    end

    it 'library uploadが1件ならbatch処理のまま単一upload文言を表示する' do
      files = [ uploaded_receipt_fixture ]
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.to change(Receipt, :count).by(1)
        .and change(ReceiptAnalysisRun, :count).by(1)

      receipt = Receipt.order(:id).last
      run = receipt.receipt_analysis_runs.sole

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt).to be_processing
        expect(receipt.image).to be_attached
        expect(run.source).to eq('batch_upload')
        expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
        expect(flash[:notice]).to eq(I18n.t('flash.receipts.enqueued'))
        expect(flash[:notice]).not_to eq(I18n.t('flash.receipts.batch_enqueued', count: 1))
      end
    end

    it 'active runが既にある場合はduplicate enqueueしない' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      existing_run = instance_double(ReceiptAnalysisRun, id: 12_345)
      allow(Receipts::Processing).to receive(:start).and_return(
        Receipts::Processing::StartResult.new(run: existing_run, created: false)
      )

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(Receipts::Processing).to have_received(:start).with(
          receipt: Receipt.order(:id).last,
          source: 'upload',
          requested_by_user: user
        )
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it 'library複数uploadでreceiptごとにsource: batch_uploadのrunを作成しrun_id付きOCR jobをenqueueする' do
      files = [
        uploaded_receipt_fixture,
        uploaded_receipt_fixture('single_tax_receipt.png', 'image/png'),
        uploaded_receipt_fixture('multiple_tax_receipt.png', 'image/png')
      ]
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.to change(Receipt, :count).by(3)
        .and change(ReceiptAnalysisRun, :count).by(3)

      created_receipts = Receipt.order(:id).last(3)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(created_receipts).to all(be_processing)
        expect(created_receipts).to all(satisfy { |receipt| receipt.image.attached? })
        expect(created_receipts).to all(have_attributes(
          processing_error_code: nil,
          processing_error_message: nil,
          review_reasons: []
        ))
        created_receipts.each do |receipt|
          run = receipt.receipt_analysis_runs.sole
          expect(run.source).to eq('batch_upload')
          expect(run.requested_by_user).to eq(user)
          expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
        end
      end
    end

    it 'library uploadが2件ならbatch upload文言に作成件数を表示する' do
      files = [
        uploaded_receipt_fixture,
        uploaded_receipt_fixture('single_tax_receipt.png', 'image/png')
      ]
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.to change(Receipt, :count).by(2)
        .and change(ReceiptAnalysisRun, :count).by(2)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(Receipt.order(:id).last(2).flat_map(&:receipt_analysis_runs).map(&:source)).to all(eq('batch_upload'))
        expect(flash[:notice]).to eq(I18n.t('flash.receipts.batch_enqueued', count: 2))
      end
    end

    it '複数uploadが6件以上ならreceiptを作成せず解析jobもenqueueしない' do
      files = Array.new(6) { uploaded_receipt_fixture }
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.batch_upload.errors.too_many', max: Receipts::Uploads.max_files))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
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
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.invalid_content_type'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '単一uploadでテキスト/HTML/JSをJPEGに偽装してもreceiptを作成せず解析jobもenqueueしない' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      disguised_files = {
        text: uploaded_bytes(prefix: 'fake-text-receipt', extension: '.jpg', content_type: 'image/jpeg', bytes: 'plain text receipt'),
        html: uploaded_bytes(prefix: 'fake-html-receipt', extension: '.jpg', content_type: 'image/jpeg', bytes: '<html><body>not an image</body></html>'),
        javascript: uploaded_bytes(prefix: 'fake-js-receipt', extension: '.jpg', content_type: 'image/jpeg', bytes: 'alert("not an image")')
      }

      disguised_files.each do |label, file|
        aggregate_failures label do
          expect do
            post upload_receipts_path, params: { receipt: { image: file } }
          end.not_to change { [ Receipt.count, ReceiptAnalysisRun.count ] }

          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.invalid_content_type'))
          expect(ReceiptOcrJob).not_to have_received(:perform_later)
        end
      end
    end

    it '単一uploadでPDFをJPEGに偽装してもreceiptを作成せず解析jobもenqueueしない' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      file = uploaded_bytes(
        prefix: 'fake-pdf-receipt',
        extension: '.jpg',
        content_type: 'image/jpeg',
        bytes: "%PDF-1.7\nnot a receipt image"
      )

      expect do
        post upload_receipts_path, params: { receipt: { image: file } }
      end.not_to change { [ Receipt.count, ReceiptAnalysisRun.count ] }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.invalid_content_type'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '単一uploadでSVGをPNGに偽装してもreceiptを作成せず解析jobもenqueueしない' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      file = uploaded_bytes(
        prefix: 'fake-svg-receipt',
        extension: '.png',
        content_type: 'image/png',
        bytes: '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
      )

      expect do
        post upload_receipts_path, params: { receipt: { image: file } }
      end.not_to change { [ Receipt.count, ReceiptAnalysisRun.count ] }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.invalid_content_type'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '単一uploadで拡張子なしでも実体が正常PNGならreceiptを作成し解析jobをenqueueする' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      file = uploaded_bytes(
        prefix: 'receipt-no-extension',
        extension: nil,
        content_type: 'application/octet-stream',
        bytes: png_bytes(width: 120, height: 120)
      )

      expect do
        post upload_receipts_path, params: { receipt: { image: file } }
      end.to change(Receipt, :count).by(1)
        .and change(ReceiptAnalysisRun, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(Receipt.order(:id).last.image.blob.content_type).to eq('image/png')
        expect(ReceiptOcrJob).to have_received(:perform_later)
      end
    end

    it '単一uploadでcontent_typeがtext/plainでも実体が正常PNGならreceiptを作成し解析jobをenqueueする' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      file = uploaded_bytes(
        prefix: 'receipt-real-png',
        extension: '.txt',
        content_type: 'text/plain',
        bytes: png_bytes(width: 120, height: 120)
      )

      expect do
        post upload_receipts_path, params: { receipt: { image: file } }
      end.to change(Receipt, :count).by(1)
        .and change(ReceiptAnalysisRun, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(Receipt.order(:id).last.image.blob.content_type).to eq('image/png')
        expect(ReceiptOcrJob).to have_received(:perform_later)
      end
    end

    it '単一uploadで拡張子なしの非画像はreceiptを作成せず解析jobもenqueueしない' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      file = uploaded_bytes(
        prefix: 'receipt-no-extension-invalid',
        extension: nil,
        content_type: 'application/octet-stream',
        bytes: 'not an image'
      )

      expect do
        post upload_receipts_path, params: { receipt: { image: file } }
      end.not_to change { [ Receipt.count, ReceiptAnalysisRun.count ] }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('activerecord.errors.models.receipt.attributes.image.invalid_content_type'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '小さすぎる画像はreceiptを作成せず解析jobもenqueueしない' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_png(width: 1, height: 1) } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(
          I18n.t(
            'activerecord.errors.models.receipt.attributes.image.image_too_small',
            min_dimension: Receipt.image_min_dimension
          )
        )
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '複数uploadの合計サイズが残り容量を超えるとreceiptを作成せず解析jobもenqueueしない' do
      files = [
        uploaded_receipt_fixture,
        uploaded_receipt_fixture
      ]
      user.update!(storage_limit_bytes: files.first.size + 1)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { images: files } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('receipts.batch_upload.errors.quota_exceeded'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it 'ストレージ上限超過時はreceiptを作成せず解析jobもenqueueしない' do
      user.update!(storage_limit_bytes: 1)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.storage.quota_exceeded'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '全体storage hard stop超過時はreceiptを作成せず解析jobもenqueueしない' do
      allow(Storage).to receive(:global_quota_can_add?).and_return(false)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.storage.global_hard_stop'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '単一uploadの日次上限到達時はreceiptを作成せず解析jobもenqueueしない' do
      create(:usage_counter, user: user, key: 'receipt_uploads_per_day', used_count: 50)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.usage_limits.uploads_exceeded'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
        expect(UsageCounter.find_by!(user: user, key: 'receipt_uploads_per_day').used_count).to eq(50)
      end
    end

    it 'OCR job日次上限到達時も受付時はrunを作成しOCR jobをenqueueする' do
      create(:usage_counter, user: user, key: 'ocr_jobs_per_day', used_count: 50)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)
        .and change(ReceiptAnalysisRun, :count).by(1)

      run = ReceiptAnalysisRun.order(:id).last
      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(run.status).to eq('queued')
        expect(run.error_stage).to be_nil
        expect(run.error_code).to be_nil
        expect(receipt.reload).to be_processing
        expect(receipt.processing_error_code).to be_nil
        expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
        expect(UsageCounter.find_by!(user: user, key: 'ocr_jobs_per_day').used_count).to eq(50)
      end
    end

    it 'guest単一uploadの日次上限はguest用limitで拒否する' do
      guest = create(:user, guest: true)
      sign_in guest
      create(:usage_counter, user: guest, key: 'receipt_uploads_per_day', used_count: 5)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.usage_limits.uploads_exceeded'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
        expect(UsageCounter.find_by!(user: guest, key: 'receipt_uploads_per_day').used_count).to eq(5)
      end
    end

    it 'guest OCR job日次上限到達時も受付時はrunを作成しOCR jobをenqueueする' do
      guest = create(:user, guest: true)
      sign_in guest
      create(:usage_counter, user: guest, key: 'ocr_jobs_per_day', used_count: 5)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)
        .and change(ReceiptAnalysisRun, :count).by(1)

      run = ReceiptAnalysisRun.order(:id).last
      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(run.status).to eq('queued')
        expect(run.error_stage).to be_nil
        expect(run.error_code).to be_nil
        expect(receipt.reload).to be_processing
        expect(receipt.processing_error_code).to be_nil
        expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
        expect(UsageCounter.find_by!(user: guest, key: 'ocr_jobs_per_day').used_count).to eq(5)
      end
    end

    it 'Turbo requestでもストレージ上限guardはglobal error pageへ飛ばさずupload画面を維持する' do
      user.update!(storage_limit_bytes: 1)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

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
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it 'OCR down時はreceiptを作成せず解析jobもenqueueしない' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(true)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it 'SystemSettingsでOCR停止中はreceiptを作成せず解析jobもenqueueしない' do
      create(:system_setting, key: 'operations.ocr_enabled', value: SystemSettings.stored_value(false))

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.receipts.ocr_unavailable'))
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
        expect(UsageCounter.where(user: user)).to be_empty
      end
    end

    it 'Turbo requestでもOCR down guardはglobal error pageへ飛ばさずupload画面を維持する' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(true)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'down' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

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
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it 'AI down時でもuploadは止めず解析jobをenqueueする' do
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'down' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        receipt = Receipt.order(:id).last
        run = receipt.receipt_analysis_runs.sole
        expect(ReceiptOcrJob).to have_received(:perform_later).with(run_id: run.id)
      end
    end

    it '通知OFFならupload enqueueのredirect flashを表示しない' do
      user.update!(push_notification_enabled: false)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

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
      allow(Analysis).to receive(:processing_error_mapping).and_call_original
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
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

      run = receipt.receipt_analysis_runs.sole
      perform_analysis_job_chain(run)
      receipt.reload

      aggregate_failures 'failed receipt state' do
        expect(receipt.status).to eq('failed')
        expect(receipt.processing_error_code).to eq('ocr_timeout')
        expect(ReceiptAiEnrichmentService).not_to have_received(:call)
      end

      get receipts_path
      document = Nokogiri::HTML(response.body)
      card = document.at_css("#receipt_#{receipt.public_id}")

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
      allow(Analysis).to receive(:processing_error_mapping).and_call_original
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:down?).with(:ai).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })
      allow(ReceiptOcrService).to receive(:call).and_return(upload_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call).and_return(failed_ai_result)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('processing')

      run = receipt.receipt_analysis_runs.sole
      perform_analysis_job_chain(run)
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
      card = document.at_css("#receipt_#{receipt.public_id}")

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
      allow(Analysis).to receive(:processing_error_mapping).and_call_original
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:down?).with(:ai).and_return(true)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'down' })
      allow(ReceiptOcrService).to receive(:call).and_return(upload_ocr_result)
      allow(ReceiptAiEnrichmentService).to receive(:call)

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('processing')

      run = receipt.receipt_analysis_runs.sole
      perform_analysis_job_chain(run)
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
          status: 'uploaded',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: 'テスト商品',
              price: 1000,
              quantity: 1,
              quantity_unit_code: 'each',
              line_total: 1000,
              needs_review: false
            }
          }
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

    it '手動作成成功時にmanual receipt counterを消費する' do
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 49)

      expect do
        post receipts_path, params: valid_params
      end.to change(Receipt, :count).by(1)

      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(50)
    end

    it '手動作成の日次上限到達時はreceiptを作成しない' do
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 50)

      expect do
        post receipts_path, params: valid_params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.usage_limits.manual_receipts_exceeded'))
        expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(50)
      end
    end

    it 'guestの手動作成日次上限はguest用limitで拒否する' do
      guest = create(:user, guest: true)
      sign_in guest
      create(:usage_counter, user: guest, key: 'manual_receipts_per_day', used_count: 5)

      expect do
        post receipts_path, params: valid_params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.usage_limits.manual_receipts_exceeded'))
        expect(UsageCounter.find_by!(user: guest, key: 'manual_receipts_per_day').used_count).to eq(5)
      end
    end

    it 'user overrideで手動作成日次上限を引き上げられる' do
      create(:user_limit_override, user: user, key: 'manual_receipts_per_day', value: { 'value' => 60 })
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 50)

      expect do
        post receipts_path, params: valid_params
      end.to change(Receipt, :count).by(1)

      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(51)
    end

    it 'validation error時はmanual receipt counterを消費しない' do
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 10)

      expect do
        post receipts_path, params: invalid_params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(10)
      end
    end

    it 'upload作成ではmanual receipt counterを消費しない' do
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 10)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ExternalServices).to receive(:snapshot).with(:ocr).and_return({ state: 'ok' })
      allow(ExternalServices).to receive(:snapshot).with(:ai).and_return({ state: 'ok' })

      expect do
        post upload_receipts_path, params: { receipt: { image: uploaded_image } }
      end.to change(Receipt, :count).by(1)

      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(10)
    end

    it '明細数がuser limitを超える手動作成を拒否する' do
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 1 })
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 10)
      params = valid_params.deep_dup
      params[:receipt][:receipt_items_attributes]['1'] = {
        confirmed_name: '追加商品',
        price: 200,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 200,
        needs_review: false
      }
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('明細は1件まで登録できます')
        expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(10)
      end
    end

    it 'default上限を超える101件の手動作成を金額計算前に拒否する' do
      params = valid_params.deep_dup
      params[:receipt][:total_amount] = 10_100
      params[:receipt][:receipt_items_attributes] = manual_items_params(101)
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('明細は100件まで登録できます')
      end
    end

    it 'override上限内の150件の手動作成を許可する' do
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 200 })
      params = valid_params.deep_dup
      params[:receipt][:total_amount] = 15_000
      params[:receipt][:receipt_items_attributes] = manual_items_params(150)

      expect do
        post receipts_path, params: params
      end.to change(Receipt, :count).by(1)

      aggregate_failures do
        expect(response).to have_http_status(:redirect)
        expect(Receipt.order(:id).last.receipt_items.count).to eq(150)
      end
    end

    it 'override上限を超える201件の手動作成を金額計算前に拒否する' do
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 200 })
      params = valid_params.deep_dup
      params[:receipt][:total_amount] = 20_100
      params[:receipt][:receipt_items_attributes] = manual_items_params(201)
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('明細は200件まで登録できます')
      end
    end

    it '調整行が固定上限を超える手動作成を金額計算前に拒否する' do
      params = valid_params.deep_dup
      params[:receipt][:receipt_adjustments_attributes] =
        (0..ReceiptAdjustment::MAX_PER_RECEIPT).to_h { |index| [ index.to_s, manual_adjustment_params(index) ] }
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("調整行は#{ReceiptAdjustment::MAX_PER_RECEIPT}件まで登録できます")
      end
    end

    it '調整行が設定上限を超える手動作成を金額計算前に拒否する' do
      create(:system_setting, key: 'limits.receipt_adjustments_per_receipt', value: SystemSettings.stored_value(1))
      params = valid_params.deep_dup
      params[:receipt][:receipt_adjustments_attributes] =
        {
          '0' => manual_adjustment_params(0),
          '1' => manual_adjustment_params(1)
        }
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('調整行は1件まで登録できます')
      end
    end

    it '支払い行が設定上限を超える手動作成paramsを金額計算前に拒否する' do
      create(:system_setting, key: 'limits.receipt_payments_per_receipt', value: SystemSettings.stored_value(1))
      params = valid_params.deep_dup
      params[:receipt][:receipt_payments_attributes] =
        {
          '0' => manual_payment_params(0),
          '1' => manual_payment_params(1)
        }
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('支払い行は1件まで登録できます')
      end
    end

    it '税内訳が設定上限を超える手動作成paramsを金額計算前に拒否する' do
      create(:system_setting, key: 'limits.receipt_tax_details_per_receipt', value: SystemSettings.stored_value(1))
      params = valid_params.deep_dup
      params[:receipt][:receipt_tax_details_attributes] =
        {
          '0' => manual_tax_detail_params(0),
          '1' => manual_tax_detail_params(1)
        }
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('税内訳は1件まで登録できます')
      end
    end

    it '金額上限を超える手動作成を金額計算前に拒否する' do
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(500))
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 10)
      params = valid_params.deep_dup
      params[:receipt][:receipt_items_attributes]['0'][:price] = 501
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        post receipts_path, params: params
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('receipt_items.price は500以下で入力してください')
        expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(10)
      end
    end

    it 'redirect flashをnotice_surfaceのtoastとして描画する' do
      post receipts_path, params: valid_params

      follow_redirect!

      document = Nokogiri::HTML(response.body)
      flash = document.at_css('#flash')
      toast_stream = document.at_css('#toast-stream')
      notice_surface = flash.at_css('[data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(flash).to be_present
        expect(flash['data-notice-surface-container']).to eq('')
        expect(flash['data-notice-surface-max-visible']).to eq('5')
        expect(toast_stream.ancestors).to include(flash)
        expect(toast_stream['data-notice-surface-container']).to be_nil
        expect(toast_stream['data-notice-surface-max-visible']).to be_nil
        expect(notice_surface).to be_present
        expect(notice_surface['data-notice-surface-auto-dismiss-value']).to eq('true')
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
        expect(receipt.amount_calculation_profile).to include(
          'context' => 'manual',
          'resolved' => include('total_amount' => 1000)
        )
        expect(receipt.amount_calculation_profile).not_to have_key('calculation_profile_candidates')
      end
    end

    it '画像なし作成時にstatusが入る' do
      post receipts_path, params: valid_params

      receipt = Receipt.order(:id).last
      expect(receipt.status).to eq('completed')
    end

    it '画像あり手動登録時もcompletedで保存され、解析は実行しない' do
      allow(ReceiptOcrJob).to receive(:perform_later)

      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '画像付きレシート',
            total_amount: 1500,
            payment_method: 'cash',
            image: uploaded_image,
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '画像付き商品',
                price: 1500,
                quantity: 1,
                quantity_unit_code: 'each',
                line_total: 1500,
                needs_review: false
              }
            }
          }
        }
      end.to change(Receipt, :count).by(1)

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(receipt.status).to eq('completed')
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
        expect(response).to redirect_to(receipts_path)
      end
    end

    it '画像あり手動登録はuserの画像保持設定をsnapshotし、OFFならpurge候補化する' do
      user.update!(keep_receipt_images: false)

      post receipts_path, params: {
        receipt: {
          store_name: '画像保持OFF手動登録',
          total_amount: 1500,
          payment_method: 'cash',
          image: uploaded_image,
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '画像保持OFF商品',
              price: 1500,
              quantity: 1,
              quantity_unit_code: 'each',
              line_total: 1500,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.keep_image).to be(false)
        expect(receipt.image_purge_eligible_at).to be_present
        expect(receipt.image_purged_at).to be_nil
        expect(receipt.image_purged_reason).to be_nil
      end
    end

    it '画像あり手動登録時は解析失敗処理も実行しない' do
      allow(ReceiptOcrJob).to receive(:perform_later)

      post receipts_path, params: {
        receipt: {
          store_name: '解析しない画像付きレシート',
          total_amount: 1800,
          payment_method: 'cash',
          image: uploaded_image,
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '解析しない画像付き商品',
              price: 1800,
              quantity: 1,
              quantity_unit_code: 'each',
              line_total: 1800,
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.status).to eq('completed')
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
        expect(receipt.processing_error_code).to be_nil
      end
    end

    it '画像なし作成時は解析を実行しない' do
      allow(ReceiptOcrJob).to receive(:perform_later)

      post receipts_path, params: valid_params

      expect(ReceiptOcrJob).not_to have_received(:perform_later)
    end

    it '不正なパラメータでは作成できない' do
      expect do
        post receipts_path, params: invalid_params
      end.not_to change(Receipt, :count)

      expect([ 200, 422 ]).to include(response.status)
    end

    it '手動新規のvalidation失敗時は未入力金額を未設定表示のまま維持する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash'
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(document.at_css('[data-receipt-form-target="totalAmount"]').text.strip).to eq(I18n.t('receipts.common.unset'))
        expect(document.at_css('[data-receipt-form-target="subtotalAmount"]').text.strip).to eq(I18n.t('receipts.common.not_available'))
        expect(document.at_css('[data-receipt-form-target="taxAmount"]').text.strip).to eq(I18n.t('receipts.common.not_available'))
      end
    end

    it '空の初期明細行だけで手動保存した場合は明細向けエラーを表示し明細行を再表示する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '',
                category: '',
                price: '',
                quantity: '1',
                quantity_unit_code: 'each',
                product_code: '',
                discount_rate: '',
                tax_rate: '',
                line_total: '0',
                needs_review: false,
                _destroy: '0'
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(notice_surface.text).not_to include('合計金額を入力してください')
        expect(notice_surface.text).not_to include('合計金額は数値で入力してください')
        expect(rendered_receipt_item_rows(document).size).to eq(1)
      end
    end

    it '明細行を意図的に全削除して手動保存した場合は空状態を維持する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '',
                price: '',
                quantity: '1',
                quantity_unit_code: 'each',
                line_total: '0',
                needs_review: false,
                _destroy: '1'
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(notice_surface.text).not_to include('合計金額を入力してください')
        expect(rendered_receipt_item_rows(document)).to be_empty
      end
    end

    it '入力済み明細があるvalidation失敗では入力内容を保持する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '保持する商品',
                price: '120',
                quantity: '2',
                quantity_unit_code: 'each',
                tax_rate: '10',
                line_total: '',
                needs_review: false
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      item_row = rendered_receipt_item_rows(document).first

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(rendered_receipt_item_rows(document).size).to eq(1)
        expect(item_row.at_css('input[name*="[confirmed_name]"]')['value']).to eq('保持する商品')
        expect(item_row.at_css('input[name*="[price]"]')['value']).to eq('120')
      end
    end

    it '手動新規のvalidation失敗時も明示0入力は0円表示を維持する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash',
            total_amount: '0',
            subtotal_amount: '0',
            tax_amount: '0'
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(document.at_css('[data-receipt-form-target="totalAmount"]').text.strip).to eq('¥0')
        expect(document.at_css('[data-receipt-form-target="subtotalAmount"]').text.strip).to eq('¥0')
        expect(document.at_css('[data-receipt-form-target="taxAmount"]').text.strip).to eq('¥0')
      end
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
              quantity_unit_code: 'each',
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

    it 'native engineでも明細あり作成時は税込明細入力を正として保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: 'native engine 明細あり作成',
          payment_method: 'cash',
          total_amount: 9_999,
          subtotal_amount: 9_000,
          tax_amount: 999,
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 108,
              quantity: 2,
              quantity_unit_code: 'each',
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
        # 検算: Recifyの手動入力単価は税込基準。108 * 2 = 216、内税10%は 216 * 10 / 110 = 19。
        expect(response).to redirect_to(receipts_path)
        expect(receipt.subtotal_amount).to eq(197)
        expect(receipt.tax_amount).to eq(19)
        expect(receipt.total_amount).to eq(216)
        expect(item.line_total).to eq(216)
        expect(receipt.amount_calculation_profile.dig('amount_engine', 'selected_basis')).to eq('items_as_tax_included')
      end
    end

    it 'direct paramsでmanual service_chargeを作成できる' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '手動調整作成',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '商品A',
                price: 1000,
                quantity: 1,
                quantity_unit_code: 'each',
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            },
            receipt_adjustments_attributes: {
              '0' => {
                kind: 'service_charge',
                label: 'サービス料',
                amount: '110',
                sign: 'surcharge',
                tax_rate: '10',
                position_index: '0'
              }
            }
          }
        }
      end.to change(ReceiptAdjustment, :count).by(1)

      receipt = Receipt.order(:id).last
      adjustment = receipt.receipt_adjustments.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(1110)
        expect(receipt.tax_amount).to eq(100)
        expect(adjustment.kind).to eq('service_charge')
        expect(adjustment.label).to eq('サービス料')
        expect(adjustment.amount).to eq(110)
        expect(adjustment.sign).to eq('surcharge')
        expect(adjustment.tax_rate).to eq(BigDecimal('0.1'))
        expect(adjustment.source).to eq('manual')
        expect(adjustment.needs_review).to be(false)
        expect(adjustment.review_reasons).to eq([])
      end
    end

    it 'delivery_feeとbag_feeを手動加算として合計へ反映する' do
      post receipts_path, params: {
        receipt: {
          store_name: '送料袋代作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1000,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'delivery_fee',
              label: '配送料',
              amount: '550',
              sign: 'discount',
              tax_rate: '10'
            },
            '1' => {
              kind: 'bag_fee',
              label: '袋代',
              amount: '10',
              sign: 'discount',
              tax_rate: '10'
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(1560)
        expect(receipt.receipt_adjustments.pluck(:kind, :sign, :source)).to contain_exactly(
          [ 'delivery_fee', 'surcharge', 'manual' ],
          [ 'bag_fee', 'surcharge', 'manual' ]
        )
      end
    end

    it 'service_chargeとlate_night_chargeを税率別サマリーへ反映する' do
      post receipts_path, params: {
        receipt: {
          store_name: 'サービス深夜作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1000,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'service_charge',
              label: 'サービス料',
              amount: '100',
              sign: 'surcharge',
              tax_rate: '10'
            },
            '1' => {
              kind: 'late_night_charge',
              label: '深夜料金',
              amount: '100',
              sign: 'surcharge',
              tax_rate: '10'
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      tax_detail = receipt.receipt_tax_details.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(1200)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(tax_detail.rate).to eq(BigDecimal('0.1'))
        expect(tax_detail.net_amount + tax_detail.amount).to eq(1200)
      end
    end

    it 'couponを手動減算として合計へ反映する' do
      post receipts_path, params: {
        receipt: {
          store_name: 'クーポン作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1000,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'coupon',
              label: 'クーポン',
              amount: '110',
              sign: 'surcharge',
              tax_rate: '10'
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      adjustment = receipt.receipt_adjustments.first
      tax_detail = receipt.receipt_tax_details.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(890)
        expect(receipt.tax_amount).to eq(80)
        expect(adjustment.kind).to eq('coupon')
        expect(adjustment.sign).to eq('discount')
        expect(adjustment.source).to eq('manual')
        expect(tax_detail.rate).to eq(BigDecimal('0.1'))
        expect(tax_detail.net_amount + tax_detail.amount).to eq(890)
      end
    end

    it 'receipt_discountを手動減算として合計へ反映する' do
      post receipts_path, params: {
        receipt: {
          store_name: 'レシート値引き作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1000,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'receipt_discount',
              label: '全体値引き',
              amount: '100',
              sign: 'surcharge',
              tax_rate: '10'
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(900)
        expect(receipt.receipt_adjustments.first.sign).to eq('discount')
      end
    end

    it 'return_refundを負値itemではなくadjustmentとして保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '返品作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1980,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'return_refund',
              label: '返品',
              amount: '980',
              sign: 'surcharge',
              tax_rate: '10'
            }
          }
        }
      }

      receipt = Receipt.order(:id).last

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(1000)
        expect(receipt.receipt_items.pluck(:price)).to contain_exactly(1980)
        expect(receipt.receipt_adjustments.pluck(:kind, :amount, :sign)).to contain_exactly([ 'return_refund', 980, 'discount' ])
      end
    end

    it 'manual other + surchargeは通常のadjustmentとして保存しcompletedになる' do
      post receipts_path, params: {
        receipt: {
          store_name: 'その他加算作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1000,
              quantity: 1,
              quantity_unit_code: 'each',
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'other',
              label: '調整加算',
              amount: '100',
              sign: 'surcharge',
              tax_rate: ''
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      adjustment = receipt.receipt_adjustments.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(1100)
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).not_to include('adjustment_uncertain')
        expect(adjustment.kind).to eq('other')
        expect(adjustment.sign).to eq('surcharge')
        expect(adjustment.source).to eq('manual')
      end
    end

    it 'manual other + discountは通常のadjustmentとして保存しcompletedになる' do
      post receipts_path, params: {
        receipt: {
          store_name: 'その他減算作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1000,
              quantity: 1,
              quantity_unit_code: 'each',
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'other',
              label: '調整減算',
              amount: '100',
              sign: 'discount',
              tax_rate: ''
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      adjustment = receipt.receipt_adjustments.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.total_amount).to eq(900)
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).not_to include('adjustment_uncertain')
        expect(adjustment.kind).to eq('other')
        expect(adjustment.sign).to eq('discount')
        expect(adjustment.source).to eq('manual')
      end
    end

    it 'point_usageを税額計算から外して支払調整として保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: 'ポイント利用作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '商品A',
              price: 1100,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'point_usage',
              label: 'ポイント利用',
              amount: '500',
              sign: 'surcharge',
              tax_rate: '10'
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      adjustment = receipt.receipt_adjustments.first
      tax_detail = receipt.receipt_tax_details.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
        expect(receipt.total_amount).to eq(1100)
        expect(receipt.tax_amount).to eq(100)
        expect(tax_detail.net_amount).to eq(1000)
        expect(tax_detail.amount).to eq(100)
        expect(adjustment.kind).to eq('point_usage')
        expect(adjustment.sign).to eq('discount')
        expect(receipt.amount_calculation_profile.dig('computed', 'payment_adjustment_total')).to eq(-500)
      end
    end

    it 'blank adjustment rowは保存されない' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '空調整除外',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '商品A',
                price: 100,
                quantity: 1,
                quantity_unit_code: 'each',
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            },
            receipt_adjustments_attributes: {
              '0' => {
                kind: '',
                label: '',
                amount: '',
                sign: '',
                tax_rate: '',
                position_index: ''
              }
            }
          }
        }
      end.to change(Receipt, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(Receipt.order(:id).last.receipt_adjustments).to be_empty
      end
    end

    it 'validation error後にadjustment行を復元する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '商品A',
                price: 1000,
                quantity: 1,
                quantity_unit_code: 'each',
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            },
            receipt_adjustments_attributes: {
              '0' => {
                kind: 'delivery_fee',
                label: '配送料',
                amount: '550',
                sign: 'surcharge',
                tax_rate: '10'
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      visible_adjustment_rows = document.css('[data-receipt-form-target="adjustmentRow"]').reject do |node|
        node.ancestors.any? { |ancestor| ancestor.name == 'template' }
      end
      adjustment_row = visible_adjustment_rows.first

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_adjustment_rows.size).to eq(1)
        expect(adjustment_row).to be_present
        expect(adjustment_row.at_css('input[name*="[label]"]')['value']).to eq('配送料')
        expect(adjustment_row.at_css('input[name*="[amount]"]')['value']).to eq('550')
        expect(adjustment_row.at_css('input[name*="[sign]"]')['value']).to eq('surcharge')
      end
    end

    it '空のadjustment行を追加したvalidation error後は空行を再表示する' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '商品A',
                price: 1000,
                quantity: 1,
                quantity_unit_code: 'each',
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            },
            receipt_adjustments_attributes: {
              '0' => {
                kind: 'delivery_fee',
                label: '',
                amount: '',
                sign: 'surcharge',
                tax_rate: ''
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      visible_adjustment_rows = document.css('[data-receipt-form-target="adjustmentRow"]').reject do |node|
        node.ancestors.any? { |ancestor| ancestor.name == 'template' }
      end
      adjustment_row = visible_adjustment_rows.first

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_adjustment_rows.size).to eq(1)
        expect(adjustment_row.at_css('input[name*="[label]"]')['value'].to_s).to eq('')
        expect(adjustment_row.at_css('input[name*="[amount]"]')['value'].to_s).to eq('')
        expect(adjustment_row.at_css('select[name*="[kind]"] option[selected]')&.[]('value')).to eq('delivery_fee')
      end
    end

    it 'adjustment未追加のvalidation errorでは空adjustment行を出さない' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '商品A',
                price: 1000,
                quantity: 1,
                quantity_unit_code: 'each',
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      visible_adjustment_rows = document.css('[data-receipt-form-target="adjustmentRow"]').reject do |node|
        node.ancestors.any? { |ancestor| ancestor.name == 'template' }
      end

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(visible_adjustment_rows).to be_empty
      end
    end

    it '手動作成時にcurrent_userのrounding modeをReceiptAmountServiceへ渡す' do
      user.update!(tax_rounding_mode: 'ceil', discount_rounding_mode: 'floor')
      observed_kwargs = nil
      allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
        observed_kwargs = kwargs
        original.call(**kwargs)
      end

      post receipts_path, params: {
        receipt: {
          store_name: '丸め設定作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '丸め設定商品',
              price: 999,
              quantity: 1,
              quantity_unit_code: 'each',
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
        expect(observed_kwargs[:context]).to eq(:manual)
        expect(observed_kwargs[:tax_rounding_mode]).to eq('ceil')
        expect(observed_kwargs[:discount_rounding_mode]).to eq('floor')
        expect(item.discount_amount).to eq(104)
        expect(receipt.tax_amount).to eq(82)
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
              quantity_unit_code: 'each',
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

    it '空の新規明細行だけでは保存せずline_total 0の明細も作らない' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '空明細除外',
            payment_method: 'cash',
            total_amount: '500',
            subtotal_amount: '455',
            tax_amount: '45',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '',
                category: '',
                price: '',
                quantity: '1',
                quantity_unit_code: 'each',
                product_code: '',
                discount_rate: '',
                tax_rate: '',
                line_total: '0',
                needs_review: false
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')
      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(rendered_receipt_item_rows(document).size).to eq(1)
      end
    end

    it '空欄quantityは1として保存し、price/tax_rate/discount_rateの空欄はnilを維持する' do
      post receipts_path, params: {
        receipt: {
          store_name: '数量空欄作成',
          payment_method: 'cash',
          total_amount: '0',
          subtotal_amount: '0',
          tax_amount: '0',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '金額未入力商品',
              price: '',
              quantity: '',
              quantity_unit_code: 'each',
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
        expect(item.discount_amount).to be_nil
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
              quantity_unit_code: 'each',
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

    it '0円明細作成時はhidden line_totalが古くても単価0から0円で保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '0円明細作成 stale total',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '0円商品',
              price: '0',
              quantity: '1',
              quantity_unit_code: 'each',
              discount_rate: '',
              tax_rate: '',
              line_total: '1',
              needs_review: false
            }
          }
        }
      }

      receipt = Receipt.order(:id).last
      item = receipt.receipt_items.first

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(item.confirmed_name).to eq('0円商品')
        expect(item.price).to eq(0)
        expect(item.line_total).to eq(0)
        expect(receipt.total_amount).to eq(0)
        expect(receipt.subtotal_amount).to eq(0)
        expect(receipt.tax_amount).to eq(0)
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
              quantity_unit_code: 'each',
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
        expect(item.discount_amount).to eq(0)
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
              quantity_unit_code: 'each',
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

    it 'discount_rate と discount_amount の空欄はdiscount_amount nilとして保存する' do
      post receipts_path, params: {
        receipt: {
          store_name: '割引なし作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '通常商品',
              price: 310,
              quantity: 1,
              quantity_unit_code: 'each',
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
        expect(item.discount_amount).to be_nil
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
                quantity_unit_code: 'each',
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

    it 'measurement unitの小数quantityとquantity_unit_codeを保存し、明示line_totalを維持する' do
      post receipts_path, params: {
        receipt: {
          store_name: '量り売り作成',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '量り売り商品',
              price: 14_400,
              quantity: '0.300',
              quantity_unit_code: 'kilogram',
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
        expect(item.quantity_unit_code).to eq('kilogram')
        expect(item.quantity_unit_code).to eq('kilogram')
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
              quantity_unit_code: 'kilogram',
              tax_rate: 10,
              line_total: '4,320',
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
        expect(items.first.quantity_unit_code).to eq('kilogram')
        expect(items.first.quantity_unit_code).to eq('kilogram')
        expect(items.first.line_total).to eq(4_320)
        expect(items.second.line_total).to eq(4_320)
      end
    end

    it 'integer-only unitの小数quantityはJSなしでも保存しない' do
      expect do
        post receipts_path, params: {
          receipt: {
            store_name: '不正数量作成',
            payment_method: 'cash',
            receipt_items_attributes: {
              '0' => {
                confirmed_name: '小数個数商品',
                price: 100,
                quantity: '1.1',
                quantity_unit_code: 'each',
                tax_rate: 10,
                line_total: nil,
                needs_review: false
              }
            }
          }
        }
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('数量はこの単位では整数で入力してください')
      end
    end

    it 'measurement unitのline_total nilはprice multiplied by quantityで自動補完しない' do
      post receipts_path, params: {
        receipt: {
          store_name: 'measurement line_total nil 作成',
          payment_method: 'cash',
          total_amount: '0',
          subtotal_amount: '0',
          tax_amount: '0',
          receipt_items_attributes: {
            '0' => {
              confirmed_name: '量り売り商品',
              price: 14_400,
              quantity: '0.300',
              quantity_unit_code: 'kilogram',
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
        expect(item.quantity_unit_code).to eq('kilogram')
        expect(item.quantity_unit_code).to eq('kilogram')
        expect(item.line_total).to eq(0)
      end
    end

    it '明細なし手動作成時は入力金額があっても保存しない' do
      expect do
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
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(notice_surface.text).not_to include('合計金額を入力してください')
        expect(notice_surface.text).not_to include('合計金額は数値で入力してください')
      end
    end

    it '明細なし手動作成時はcomma区切り入力金額があっても保存しない' do
      expect do
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
      end.not_to change(Receipt, :count)

      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(notice_surface.text).not_to include('合計金額を入力してください')
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
              quantity_unit_code: 'each',
              tax_rate: 8,
              line_total: nil,
              needs_review: false
            },
            '1' => {
              confirmed_name: '標準税率商品',
              price: 110,
              quantity: 1,
              quantity_unit_code: 'each',
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
                quantity_unit_code: 'each',
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
              quantity_unit_code: 'each',
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
              quantity_unit_code: 'each',
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
      allow(Analysis).to receive(:processing_error_mapping).and_return({ error_category: 'ocr_error' })

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

  describe 'GET /receipts/:public_id' do
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

      aggregate_failures do
        expect(receipt_path(receipt)).to eq("/receipts/#{receipt.public_id}")
        expect(response).to have_http_status(:success)
      end
    end

    it '内部IDのURLでは取得できない' do
      get "/receipts/#{receipt.id}"

      expect(response).to have_http_status(:not_found)
    end

    it '隔離中のレシートは404扱いにする' do
      quarantined_receipt = create(:receipt, :quarantined, user: user, status: 'completed')

      get receipt_path(quarantined_receipt)

      expect(response).to have_http_status(:not_found)
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

    it '画像ダウンロードリンクはTurbo遷移扱いにしない' do
      image_receipt = create(:receipt, :completed, :with_image, user: user)

      get receipt_path(image_receipt)

      document = Nokogiri::HTML(response.body)
      download_link = document.at_css('a[download]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(download_link).to be_present
        expect(download_link['data-turbo']).to eq('false')
      end
    end

    it '詳細画面に特殊加減算を読み取り専用で表示する' do
      receipt.receipt_adjustments.create!(
        kind: 'delivery_fee',
        label: '配送料',
        amount: 550,
        sign: 'surcharge',
        source: 'manual',
        needs_review: false,
        position_index: 1
      )

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.text).to include(I18n.t('receipts.show.adjustments_title'))
        expect(document.text).to include('配送料')
        expect(document.text).to include(I18n.t('enums.receipt_adjustment.kind.delivery_fee'))
        expect(document.text).to include('+¥550')
      end
    end

    it '詳細画面は支払調整がある時だけ支払調整と実支払額を表示する' do
      receipt.update!(
        subtotal_amount: 1_066,
        tax_amount: 95,
        total_amount: 1_161,
        amount_calculation_profile: {
          computed: {
            payment_adjustment_total: -22,
            final_payment_total: 1_139
          }
        }
      )
      receipt.receipt_adjustments.create!(
        kind: 'receipt_discount',
        label: 'キャッシュレス還元額',
        amount: 22,
        sign: 'discount',
        source: 'ai',
        source_text: 'キャッシュレス還元額 -22',
        needs_review: false,
        position_index: 1
      )

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      text = document.text.squish

      aggregate_failures do
        # 検算: 購入合計 1,161 + 支払調整 -22 = 実支払額 1,139。
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-receipt-form-target="totalAmount"]').text.strip).to eq('¥1,161')
        expect(text).to include("#{I18n.t('shared.amount_summary_card.payment_adjustment')} -¥22")
        expect(text).to include("#{I18n.t('shared.amount_summary_card.final_payment_total')} ¥1,139")
      end
    end

    it '詳細画面は支払調整がない時は実支払額を表示しない' do
      receipt.update!(
        amount_calculation_profile: {
          computed: {
            payment_adjustment_total: 0,
            final_payment_total: receipt.total_amount
          }
        }
      )

      get receipt_path(receipt)

      text = Nokogiri::HTML(response.body).text

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(text).not_to include(I18n.t('shared.amount_summary_card.payment_adjustment'))
        expect(text).not_to include(I18n.t('shared.amount_summary_card.final_payment_total'))
      end
    end

    it '詳細画面の税率表示はreceipt_tax_detailsが複数なら明細税率より優先して複数税率を表示する' do
      receipt.receipt_items.create!(
        confirmed_name: 'MIX SWEETS',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit_code: 'kilogram',
        line_total: 4_320,
        tax_rate: BigDecimal('0.08'),
        needs_review: false
      )
      receipt.receipt_items.create!(
        confirmed_name: 'アウトレット袋S',
        price: 44,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 44,
        tax_rate: BigDecimal('0.08'),
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.08'),
        net_amount: 2_160,
        amount: 160,
        description: '8%対象'
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.10'),
        net_amount: 44,
        amount: 4,
        description: '10%対象'
      )

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(amount_summary_tax_rate_value(document)).to eq(I18n.t('receipts.common.multiple_tax_rates'))
      end
    end

    it '詳細画面の税率表示はreceipt_tax_detailsが1件ならitemsと矛盾してもtax_detailsのrateを表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '税率推定ミス商品',
        price: 1_000,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 1_000,
        tax_rate: BigDecimal('0.08'),
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.10'),
        net_amount: 1_000,
        amount: 91,
        description: '10%対象'
      )

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(amount_summary_tax_rate_value(document)).to eq('10%')
      end
    end

    it '詳細画面の税率表示はreceipt_tax_detailsが空なら従来通りitemsのtax_rateから推定する' do
      receipt.receipt_items.create!(
        confirmed_name: '軽減税率商品',
        price: 1_000,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 1_000,
        tax_rate: BigDecimal('0.08'),
        needs_review: false
      )

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(amount_summary_tax_rate_value(document)).to eq('8%')
      end
    end

    it '詳細画面はdisplay_idを表示し、receiptの内部IDをURLやDOMに出さない' do
      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      copy_sources = document.css('[data-controller="clipboard"] [data-clipboard-target="source"]').map { |node| node.text.strip }
      copy_labels = document.css('button[data-action="click->clipboard#copy"]').map { |node| node['aria-label'] }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include("ID: #{receipt.display_id}")
        expect(copy_sources).to eq([ receipt.display_id, receipt.display_id ])
        expect(copy_labels).to all(eq(I18n.t('shared.clipboard.copy_label', label: 'ID')))
        expect(response.body).not_to include("#RCP-#{receipt.id.to_s.rjust(6, '0')}")
        expect(response.body).not_to include("/receipts/#{receipt.id}")
        expect(response.body).not_to include("receipt_#{receipt.id}")
      end
    end

    it '詳細ヘッダーは店舗名の表示幅を優先し、statusとIDを店舗名行から分離する' do
      receipt.update!(
        store_name: 'とても長い店舗名' * 10,
        store_address: '東京都千代田区とても長い住所' * 10
      )

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      main = document.at_css('#receipt-detail-main')
      store_heading = main.css('h2').find { |node| node.text.include?(receipt.store_name) }
      text_column = store_heading.parent
      info_row = text_column.parent
      header = info_row.parent
      address = text_column.css('p').find { |node| node.text.include?(receipt.store_address) }
      mobile_eyebrow_row = header.css('div').find do |node|
        node['class'].to_s.include?('md:hidden') &&
          node['class'].to_s.include?('justify-between') &&
          node.text.include?(I18n.t('receipts.show.store_information')) &&
          node.text.include?(receipt.status_label)
      end
      desktop_badge_area = header.css('div').find do |node|
        node['class'].to_s.include?('hidden') &&
          node['class'].to_s.include?('md:block') &&
          node.text.include?(receipt.status_label)
      end
      id_nodes = main.css('p').select { |node| node['title'] == "ID: #{receipt.display_id}" }
      mobile_id = text_column.css('p').find do |node|
        node['class'].to_s.include?('md:hidden') && node['title'] == "ID: #{receipt.display_id}"
      end
      desktop_id = desktop_badge_area.css('p').find { |node| node['title'] == "ID: #{receipt.display_id}" }
      floating_id_rows = id_nodes.map(&:parent).select { |node| node['class'].to_s.include?('justify-end') }
      mobile_status_badge = mobile_eyebrow_row.css('span').find { |node| node.text.strip == receipt.status_label }
      desktop_status_badge = desktop_badge_area.css('span').find { |node| node.text.strip == receipt.status_label }
      copy_sources = main.css('[data-controller="clipboard"] [data-clipboard-target="source"]').map { |node| node.text.strip }
      copy_labels = main.css('button[data-action="click->clipboard#copy"]').map { |node| node['aria-label'] }

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(header['class']).to include('md:flex')
        expect(header['class']).to include('md:justify-between')
        expect(info_row['class']).to include('mt-3')
        expect(info_row['class']).to include('flex')
        expect(info_row['class']).to include('md:flex-1')
        expect(text_column['class']).to include('min-w-0')
        expect(text_column['class']).to include('max-w-full')
        expect(text_column['class']).to include('flex-1')
        expect(text_column['class']).to include('overflow-hidden')
        expect(store_heading['class']).to include('truncate')
        expect(store_heading['title']).to eq(receipt.store_name)
        expect(address['class']).to include('truncate')
        expect(address['title']).to eq(receipt.store_address)
        expect(mobile_eyebrow_row['class']).to include('md:hidden')
        expect(desktop_badge_area['class']).to include('md:block')
        expect(desktop_badge_area['class']).to include('whitespace-nowrap')
        expect(desktop_badge_area['class']).to include('text-right')
        expect(id_nodes.size).to eq(2)
        expect(mobile_id['class']).to include('md:hidden')
        expect(desktop_id['class']).to include('mt-2')
        expect(copy_sources).to eq([ receipt.display_id, receipt.display_id ])
        expect(copy_labels).to all(eq(I18n.t('shared.clipboard.copy_label', label: 'ID')))
        expect(floating_id_rows).to be_empty
        expect(mobile_status_badge['class']).to include('shrink-0')
        expect(desktop_status_badge['class']).to include('shrink-0')
      end
    end

    it '削除導線はJSなしでもDELETE送信できるformを描画する' do
      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      delete_form = document.at_css("form[action='#{receipt_path(receipt)}'][method='post']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(delete_form).to be_present
        expect(delete_form.at_css('input[name="_method"]')['value']).to eq('delete')
        expect(delete_form.text).to include(I18n.t('common.delete'))
        expect(delete_form['data-confirm-variant']).to eq('danger')
        expect(delete_form['data-confirm-icon']).to eq('delete')
        expect(delete_form['data-confirm-confirm-label']).to eq(I18n.t('common.delete'))
        expect(delete_form['data-confirm-title']).to eq(I18n.t('receipts.show.delete_confirm_title'))
      end
    end

    it '詳細画面はnilの合計を未設定、内訳金額とrateをダッシュで表示し、明示0は0として表示する' do
      receipt.update_columns(
        total_amount: nil,
        subtotal_amount: nil,
        tax_amount: nil,
        tax_rate: nil
      )
      receipt.receipt_items.create!(
        confirmed_name: '未計算商品',
        price: nil,
        quantity: nil,
        line_total: nil,
        needs_review: false
      )
      receipt.receipt_tax_details.build(rate: nil, net_amount: nil, amount: nil).save!(validate: false)

      zero_receipt = create(
        :receipt,
        user: user,
        store_name: '0円詳細',
        total_amount: 0,
        subtotal_amount: 0,
        tax_amount: 0,
        tax_rate: 0,
        payment_method: 'cash',
        status: 'completed'
      )
      zero_receipt.receipt_items.create!(
        confirmed_name: '0円商品',
        price: 0,
        quantity: 1,
        line_total: 0,
        needs_review: false
      )

      get receipt_path(receipt)

      nil_document = Nokogiri::HTML(response.body)
      nil_text = nil_document.text.squish

      aggregate_failures 'nil display' do
        expect(nil_document.at_css('[data-receipt-form-target="totalAmount"]').text.strip).to eq(I18n.t('receipts.common.unset'))
        expect(nil_text).to include(I18n.t('shared.amount_summary_card.subtotal'))
        expect(nil_text).to include(I18n.t('shared.amount_summary_card.tax_amount'))
        expect(nil_text).to include(I18n.t('shared.amount_summary_card.tax_rate'))
        expect(nil_text).to include('未計算商品')
        expect(nil_text).to include(I18n.t('receipts.common.not_available'))
        expect(nil_text).not_to include('¥0')
        expect(nil_text).not_to include('0%')
      end

      get receipt_path(zero_receipt)

      zero_document = Nokogiri::HTML(response.body)
      zero_text = zero_document.text.squish

      aggregate_failures 'explicit zero display' do
        expect(zero_document.at_css('[data-receipt-form-target="totalAmount"]').text.strip).to eq('¥0')
        expect(zero_text).to include("#{I18n.t('shared.amount_summary_card.subtotal')} ¥0")
        expect(zero_text).to include("#{I18n.t('shared.amount_summary_card.tax_amount')} ¥0")
        expect(zero_text).to include("#{I18n.t('shared.amount_summary_card.tax_rate')} 0%")
        expect(zero_text).to include('0円商品')
        expect(zero_text).to include('¥0')
      end
    end

    it 'レスポンスにレシート情報が含まれる' do
      get receipt_path(receipt)

      expect(response.body).to include('テスト店')
    end

    it '明細数量をquantity_unit_codeの表示ラベル付きで表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit_code: 'kilogram',
        line_total: 4_320,
        needs_review: false
      )
      receipt.receipt_items.create!(
        confirmed_name: '通常商品',
        price: 100,
        quantity: 2,
        quantity_unit_code: 'each',
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

    it 'default quantity_unit_code の明細は表示上個にfallbackする' do
      receipt.receipt_items.create!(
        confirmed_name: '単位なし商品',
        price: 100,
        quantity: 2,
        quantity_unit_code: 'each',
        line_total: 200,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('数量: 2 個')
      end
    end

    it '未知単位は保存せずdetail表示ではdefault単位に整理する' do
      receipt.receipt_items.create!(
        confirmed_name: '未知単位商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: false
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('数量: 1 個')
      end
    end

    it '割引明細では割引額と割引率を表示し、右端は割引後小計を維持する' do
      receipt.receipt_items.create!(
        confirmed_name: '割引商品',
        price: 310,
        quantity: 1,
        quantity_unit_code: 'each',
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
        quantity_unit_code: 'each',
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
        quantity_unit_code: 'each',
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
        expect(response.body).not_to include('OCR service timeout')
        expect(response.body).to include('手動編集で内容を修正できます')
        expect(response.body).to include('編集して修正')
        expect(response.body).to include(edit_receipt_path(receipt, from: 'show'))
        expect(receipt.reload.processing_error_message).to eq('OCR service timeout')
      end
    end

    it '処理失敗カードにはAI内部messageを表示しない' do
      allow(Analysis).to receive(:processing_error_mapping).and_call_original

      receipt.update!(
        status: 'failed',
        processing_error_code: 'analysis_missing_keys',
        processing_error_message: 'OCR結果が不正です'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include(I18n.t('receipts.processing_errors.ai_error'))
        expect(response.body).not_to include('OCR結果が不正です')
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

    it '画像プレビューはlg以上を初期open、lg未満を初期closedとして未操作時だけresize追従する' do
      controller_source = Rails.root.join('app/javascript/controllers/receipt_image_card_controller.js').read

      aggregate_failures do
        expect(controller_source).to include("const DESKTOP_PREVIEW_MEDIA_QUERY = '(min-width: 1024px)'")
        expect(controller_source).to include('defaultOpenStateForCurrentBreakpoint')
        expect(controller_source).to include('handleBreakpointChange')
        expect(controller_source).to include('this.userHasToggled')
        expect(controller_source).to include("addEventListener('change', this.handleBreakpointChange)")
        expect(controller_source).to include("this.toggleButtonTarget.setAttribute('aria-expanded', String(this.isOpen))")
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
        expect(response.body).not_to include('development_note / not_receipt')
        expect(response.body).not_to include('not_receipt')
        expect(response.body).to include(edit_receipt_path(receipt, from: 'show'))
        expect(receipt.reload.processing_error_message).to eq('development_note / not_receipt')
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

    it '海外レシートの処理失敗カードは日本レシートのみ対応文言を表示する' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'unsupported_country',
        processing_error_message: 'country_region=USA'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('receipts.processing_error_card.failed_title'))
        expect(response.body).to include(I18n.t('receipts.processing_error_codes.unsupported_country'))
        expect(response.body).not_to include('country_region=USA')
        expect(receipt.reload.processing_error_message).to eq('country_region=USA')
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

      document = Nokogiri::HTML(response.body)
      warning_card = document.at_css('[data-receipt-warning-notes-card]')
      summary = warning_card.at_css('[data-receipt-notes-summary]')
      details = warning_card.at_css('[data-receipt-notes-details]')
      target_link = warning_card.at_css('a[data-review-reason-target-link][data-review-reason-code="ocr_low_confidence"]')
      target_link_layout = target_link&.parent

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('確認情報')
        expect(response.body).to include('OCR品質')
        expect(response.body).to include('画像の精度が低い可能性があります')
        expect(response.body).not_to include('要確認内容')
        expect(warning_card).to be_present
        expect(warning_card['open']).to be_nil
        expect(warning_card['class']).to include('min-w-0')
        expect(summary['class']).to include('min-w-0')
        expect(details['class']).to include('min-w-0')
        expect(summary.text).to include('確認情報', '1件', '内容を確認してください。')
        expect(details.text).to include('OCR品質', '画像の精度が低い可能性があります')
        expect(target_link).to be_present
        expect(target_link['class']).to include('btn-link-warning')
        expect(target_link['class']).to include('ui-touch-control')
        expect(target_link['class']).to include('shrink-0')
        expect(target_link['class']).to include('self-start')
        expect(target_link_layout['class']).to include('flex-col')
        expect(target_link_layout['class']).to include('sm:flex-row')
        expect(target_link['data-turbo']).to eq('false')
        expect(target_link.text.strip).to eq(I18n.t('receipts.review_notes_card.confirm_link'))
        expect(target_link['href']).to eq("#{edit_receipt_path(receipt, from: 'show')}##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW}")
        expect(target_link['data-review-reason-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW)
        expect(target_link['data-review-reason-anchor-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW)
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

      document = Nokogiri::HTML(response.body)
      review_card = document.at_css('[data-receipt-review-notes-card]')
      summary = review_card.at_css('[data-receipt-notes-summary]')
      details = review_card.at_css('[data-receipt-notes-details]')
      target_link = review_card.at_css('a[data-review-reason-target-link][data-review-reason-code="item_name_uncertain"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('要確認内容')
        expect(response.body).to include('AI補完')
        expect(response.body).to include('商品名の精度が低い可能性があります')
        expect(review_card).to be_present
        expect(review_card['open']).to be_nil
        expect(review_card['class']).to include('min-w-0')
        expect(summary['class']).to include('min-w-0')
        expect(details['class']).to include('min-w-0')
        expect(summary.text).to include('要確認内容', '1件', '確認が必要な項目があります。')
        expect(details.text).to include('AI補完', '商品名の精度が低い可能性があります')
        expect(target_link).to be_present
        expect(target_link['class']).to include('btn-link-danger')
        expect(target_link['data-turbo']).to eq('false')
        expect(target_link.text.strip).to eq(I18n.t('receipts.review_notes_card.confirm_link'))
        expect(target_link['href']).to eq("#{edit_receipt_path(receipt, from: 'show')}##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS}")
        expect(target_link['data-review-reason-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS)
        expect(target_link['data-review-reason-anchor-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS)
      end
    end

    it '明細ごとのreview reasonはshow画面から編集画面の該当明細行へ遷移できる' do
      review_item = receipt.receipt_items.create!(
        confirmed_name: '要確認商品',
        price: 310,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 310,
        needs_review: true,
        review_reasons: [ 'item_category_uncertain' ]
      )

      receipt.update!(status: 'review_needed', review_reasons: [])

      get receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      review_card = document.at_css('[data-receipt-review-notes-card]')
      target_id = "#{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX}#{review_item.id}"
      target_link = review_card.at_css("a[data-review-reason-target-item='#{target_id}']")

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(review_card).to be_present
        expect(target_link).to be_present
        expect(target_link['data-turbo']).to eq('false')
        expect(target_link['href']).to eq("#{edit_receipt_path(receipt, from: 'show')}##{target_id}")
        expect(target_link['data-review-reason-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS)
        expect(target_link['data-review-reason-anchor-target']).to eq(target_id)
        expect(target_link.text.strip).to eq(I18n.t('receipts.review_notes_card.confirm_link'))
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
      allow(Analysis).to receive(:processing_error_mapping).and_call_original

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
        expect(response.body).not_to include('data-review-reason-target-link')
      end
    end

    it 'AI provider失敗の処理エラーカードはAI共通文言を表示する' do
      allow(Analysis).to receive(:processing_error_mapping).and_call_original

      receipt.update!(
        status: 'review_needed',
        processing_error_code: 'ai_primary_failed'
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('処理に関する注意')
        expect(response.body).to include(I18n.t('receipts.processing_errors.ai_error'))
        expect(response.body).not_to include(I18n.t('receipts.processing_errors.system_error'))
      end
    end

    it 'system purge済み画像なしレシートでは保存なし表示を出す' do
      receipt.update!(
        keep_image: false,
        image_purged_at: 1.hour.ago,
        image_purged_reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE
      )

      get receipt_path(receipt)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include(I18n.t('shared.receipt_image_card.unsaved_empty'))
        expect(response.body).to include(I18n.t('shared.receipt_image_card.system_purged_hint'))
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

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(flash[:warning]).to eq(I18n.t('flash.receipts.processing'))
      end
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

  describe 'GET /receipts/:public_id/edit' do
    let(:receipt) do
      create(:receipt, user: user, store_name: '編集対象', total_amount: 1300, payment_method: 'cash', status: 'review_needed')
    end

    it '編集画面を取得できる' do
      get edit_receipt_path(receipt)

      expect(response).to have_http_status(:success)
    end

    it 'review状態をclient送信するhidden fieldを描画しない' do
      receipt.receipt_items.create!(
        confirmed_name: '確認対象商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: true,
        review_reasons: [ 'item_name_uncertain' ]
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.css('input[name*="[needs_review]"]')).to be_empty
        expect(document.css('input[name*="[review_reasons]"]')).to be_empty
      end
    end

    it '隔離中のレシートは編集できない' do
      quarantined_receipt = create(:receipt, :quarantined, user: user, status: 'review_needed')

      get edit_receipt_path(quarantined_receipt)

      expect(response).to have_http_status(:not_found)
    end

    it '編集画面の主要文言をlocale経由で描画しJS用文言をform data属性へ渡す' do
      receipt.receipt_tax_details.create!(rate: BigDecimal('0.1'), net_amount: 100, amount: 10)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).not_to match(/translation missing/i)
        expect(response.body).to include(I18n.t('receipts.form.titles.edit'))
        expect(response.body).to include(I18n.t('receipts.form.buttons.save'))
        expect(response.body).to include(I18n.t('receipts.common.total_amount_title'))
        expect(form['id']).to eq("edit_receipt_form_#{receipt.public_id}")
        expect(form['id']).not_to eq("edit_receipt_form_#{receipt.id}")
        expect(response.body).not_to include("/receipts/#{receipt.id}")
        expect(document.at_css(%(nav[aria-label="#{I18n.t('shared.section_header.breadcrumb_aria')}"]))).to be_present
        expect(form['data-receipt-form-subtotal-label-value']).to eq(I18n.t('receipts.item_fields.subtotal'))
        expect(form['data-receipt-form-unset-label-value']).to eq(I18n.t('receipts.common.not_available'))
        expect(form['data-receipt-form-multiple-tax-rates-label-value']).to eq(I18n.t('receipts.common.multiple_tax_rates'))
        expect(form['data-receipt-form-adjustment-payment-kinds-value']).to eq('point_usage')
        expect(form['data-receipt-form-adjustment-purchase-kinds-value'].split(',')).to contain_exactly(
          'service_charge',
          'late_night_charge',
          'delivery_fee',
          'bag_fee',
          'handling_fee',
          'coupon',
          'return_refund'
        )
        expect('キャッシュレス還元').to match(
          Regexp.new(form['data-receipt-form-adjustment-payment-label-pattern-value'], Regexp::IGNORECASE)
        )
        expect(JSON.parse(form['data-receipt-form-adjustment-tax-detail-rates-value'])).to eq([ '10' ])
        expect(form['data-receipt-form-review-item-target-prefix-value']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX)
        expect(form['data-receipt-form-review-items-target-value']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS)
      end
    end

    it '編集フォームへ支払調整effectと実支払額を渡す' do
      receipt.update!(
        subtotal_amount: 1_066,
        tax_amount: 95,
        total_amount: 1_161,
        amount_calculation_profile: {
          computed: {
            payment_adjustment_total: -22,
            final_payment_total: 1_139
          }
        }
      )
      receipt.receipt_adjustments.create!(
        kind: 'receipt_discount',
        label: 'キャッシュレス還元額',
        amount: 22,
        sign: 'discount',
        source: 'ai',
        source_text: 'キャッシュレス還元額 -22',
        needs_review: false,
        position_index: 1
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      adjustment_row = document.css('[data-receipt-form-target="adjustmentRow"]').find do |row|
        row.at_css('input[name*="[label]"]')&.[]('value') == 'キャッシュレス還元額'
      end

      aggregate_failures do
        # 検算: 購入合計 1,161 + 支払調整 -22 = 実支払額 1,139。
        expect(response).to have_http_status(:success)
        expect(adjustment_row['data-receipt-form-adjustment-effect']).to eq('payment_adjustment')
        expect(adjustment_row['data-receipt-form-adjustment-source-payment']).to eq('true')
        expect(adjustment_row['data-receipt-form-adjustment-source-non-manual']).to eq('true')
        expect(document.at_css('[data-receipt-form-target="totalAmount"]').text.strip).to eq('¥1,161')
        expect(document.at_css('[data-receipt-form-target="paymentAdjustmentAmount"]').text.strip).to eq('-¥22')
        expect(document.at_css('[data-receipt-form-target="finalPaymentAmount"]').text.strip).to eq('¥1,139')
      end
    end

    it '編集フォームへ支払い行と支払合計の照合情報を表示する' do
      receipt.update!(total_amount: 1_161, subtotal_amount: 1_061, tax_amount: 100)
      receipt.receipt_payments.create!(method: '現金', amount: 500)
      receipt.receipt_payments.create!(method: '電子マネー', amount: 661)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      payment_rows = rendered_receipt_payment_rows(document)
      text = document.text.squish

      aggregate_failures do
        # 検算: 支払合計 500 + 661 = 1,161。購入合計/実支払額 1,161 と一致する。
        expect(response).to have_http_status(:success)
        expect(payment_rows.size).to eq(2)
        expect(payment_rows.map { |row| row.at_css('[data-receipt-form-target="paymentMethodInput"]')['value'] }).to eq([ '現金', '電子マネー' ])
        expect(payment_rows.map { |row| row.at_css('[data-receipt-form-target="paymentAmountInput"]')['value'] }).to eq([ '500', '661' ])
        expect(text).to include("#{I18n.t('receipts.payment_fields.payment_amount_sum')} ¥1,161")
        expect(text).to include("#{I18n.t('receipts.payment_fields.final_payment_total')} ¥1,161")
        expect(text).to include("#{I18n.t('receipts.payment_fields.payment_difference')} ¥0")
        expect(document.at_css('[data-receipt-form-target="paymentMismatchWarning"]')['class']).to include('hidden')
      end
    end

    it '編集フォームは支払合計が不足している時に警告と実支払額同期ボタンを表示する' do
      receipt.update!(total_amount: 1_000, subtotal_amount: 910, tax_amount: 90)
      receipt.receipt_items.create!(
        confirmed_name: '商品A',
        price: 1_000,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 1_000,
        tax_rate: BigDecimal('0.1'),
        needs_review: false
      )
      receipt.receipt_adjustments.create!(
        kind: 'service_charge',
        label: 'サービス料',
        amount: 100,
        sign: 'surcharge',
        source: 'manual',
        needs_review: false
      )
      receipt.update!(total_amount: 1_100, subtotal_amount: 1_010, tax_amount: 90)
      receipt.receipt_payments.create!(method: '現金', amount: 1_000)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        # 検算: 商品 1,000 + サービス料 100 = 実支払額 1,100。支払 1,000 なので差額 -100。
        expect(response).to have_http_status(:success)
        expect(document.at_css('[data-receipt-form-target="paymentAmountSum"]').text.strip).to eq('¥1,000')
        expect(document.at_css('[data-receipt-form-target="paymentReconciliationFinalAmount"]').text.strip).to eq('¥1,100')
        expect(document.at_css('[data-receipt-form-target="paymentDifferenceAmount"]').text.strip).to eq('-¥100')
        expect(document.at_css('[data-receipt-form-target="paymentMismatchWarning"]')['class']).not_to include('hidden')
        expect(document.text).to include(I18n.t('receipts.payment_fields.sync_to_final'))
      end
    end

    it '編集フォームの単価入力欄は税込補正済みline_totalから税込priceを表示する' do
      receipt.receipt_items.destroy_all
      receipt.receipt_items.create!(
        suggested_name: '手巻おにぎり辛子明太子',
        category: 'food',
        price: 130,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 130,
        line_total: 140,
        tax_rate: BigDecimal('0.08'),
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      item_row = document.at_css('[data-receipt-form-target="itemRow"]')

      aggregate_failures do
        # 検算: 保存済みpriceがOCR由来の130円でも、line_totalは130税抜 -> 140税込へ補正済みなので入力欄は140を表示する。
        expect(response).to have_http_status(:success)
        expect(item_row.at_css('[data-receipt-form-target="priceInput"]')['value']).to eq('140')
        expect(item_row.at_css('[data-receipt-form-target="lineTotalInput"]')['value']).to eq('140')
        expect(item_row.at_css('[data-receipt-form-target="lineTotalInput"]')['data-original-line-total']).to eq('130')
      end
    end

    it '割引あり明細の単価入力欄は税込補正済みline_totalから逆算しない' do
      receipt.receipt_items.destroy_all
      receipt.receipt_items.create!(
        suggested_name: '割引対象商品',
        category: 'daily_goods',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        original_line_total: 100,
        line_total: 110,
        discount_rate: BigDecimal('0.10'),
        tax_rate: BigDecimal('0.10'),
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      item_row = document.at_css('[data-receipt-form-target="itemRow"]')

      aggregate_failures do
        # 検算: line_totalは100税抜 -> 110税込へ補正済みでも、割引率付きのpriceは明細計算の意味を持つため100を維持する。
        expect(response).to have_http_status(:success)
        expect(item_row.at_css('[data-receipt-form-target="priceInput"]')['value']).to eq('100')
        expect(item_row.at_css('[data-receipt-form-target="lineTotalInput"]')['value']).to eq('110')
      end
    end

    it '編集画面の税率サマリーもreceipt_tax_detailsを優先する' do
      receipt.receipt_items.create!(
        confirmed_name: 'MIX SWEETS',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit_code: 'kilogram',
        line_total: 4_320,
        tax_rate: BigDecimal('0.08'),
        needs_review: false
      )
      receipt.receipt_items.create!(
        confirmed_name: 'アウトレット袋S',
        price: 44,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 44,
        tax_rate: BigDecimal('0.08'),
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.08'),
        net_amount: 2_160,
        amount: 160,
        description: '8%対象'
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.10'),
        net_amount: 44,
        amount: 4,
        description: '10%対象'
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(amount_summary_tax_rate_value(document)).to eq(I18n.t('receipts.common.multiple_tax_rates'))
      end
    end

    it 'receipt image cardにJS用文言をdata属性で渡す' do
      receipt.update!(review_reasons: [ 'ocr_low_confidence' ])
      receipt.image.attach(uploaded_image)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      warning_card = document.at_css('[data-receipt-warning-notes-card]')
      target_link = warning_card.at_css('a[data-review-reason-target-link][data-review-reason-code="ocr_low_confidence"]')
      image_section = document.at_css("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW}")
      image_card = document.at_css('[data-controller~="receipt-image-card"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(image_section).to be_present
        expect(image_card).to be_present
        expect(image_section.css('[data-controller~="receipt-image-card"]')).to include(image_card)
        expect(image_card['data-receipt-image-card-unselected-label-value']).to eq(I18n.t('shared.receipt_image_card.js.unselected'))
        expect(image_card['data-receipt-image-card-initially-open-value']).to eq('false')
        expect(image_card['data-receipt-image-card-collapse-on-mobile-value']).to eq('false')
        expect(image_card['data-receipt-image-card-empty-file-label-value']).to eq(I18n.t('shared.receipt_image_card.js.empty_file'))
        expect(image_card['data-receipt-image-card-storage-used-bytes-value']).to eq(user.storage_used_bytes.to_s)
        expect(image_card['data-receipt-image-card-storage-limit-bytes-value']).to eq(user.storage_limit_bytes.to_s)
        expect(image_card['data-receipt-image-card-storage-excluding-blob-bytes-value']).to eq(receipt.image.blob.byte_size.to_s)
        expect(image_card['data-receipt-image-card-quota-exceeded-message-value']).to eq(I18n.t('shared.receipt_image_card.quota_exceeded'))
        expect(image_card['data-receipt-image-card-review-target-value']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW)
        expect(target_link).to be_present
        expect(target_link['href']).to eq("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW}")
        expect(target_link['data-review-reason-target']).to eq(image_card['data-receipt-image-card-review-target-value'])
        expect(target_link['data-review-reason-anchor-target']).to eq(image_card['data-receipt-image-card-review-target-value'])
        expect(target_link['data-turbo']).to eq('false')
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
        expect(response.body).not_to include('OCR service timeout')
        expect(receipt.reload.processing_error_message).to eq('OCR service timeout')
      end
    end

    it 'processing receipt は編集へ進めない' do
      processing_receipt = create(:receipt, :processing, :with_image, user: user)

      get edit_receipt_path(processing_receipt)

      expect(response).to redirect_to(receipts_path)
    end

    it '削除確認設定がONならformにdelete confirmation value trueを渡す' do
      user.update!(delete_confirmation_enabled: true)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      aggregate_failures do
        expect(form['data-receipt-form-delete-confirmation-enabled-value']).to eq('true')
        expect(form['data-receipt-form-delete-confirmation-message-value']).to eq(I18n.t('receipts.form.delete_item_confirm'))
        expect(form['data-receipt-form-delete-adjustment-confirmation-message-value']).to eq(I18n.t('receipts.form.delete_adjustment_confirm'))
        expect(form['data-receipt-form-delete-payment-confirmation-message-value']).to eq(I18n.t('receipts.form.delete_payment_confirm'))
        expect(form['data-receipt-form-delete-confirm-title-value']).to eq(I18n.t('receipts.form.delete_confirm_title'))
        expect(form['data-receipt-form-delete-confirm-label-value']).to eq(I18n.t('common.delete'))
        expect(form['data-receipt-form-delete-confirm-backdrop-value']).to eq('plain')
      end
    end

    it '削除確認設定がOFFならformにdelete confirmation value falseを渡す' do
      user.update!(delete_confirmation_enabled: false)

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      form = document.at_css('[data-controller~="receipt-form"]')

      expect(form['data-receipt-form-delete-confirmation-enabled-value']).to eq('false')
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
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.08'),
        line_total: 216,
        needs_review: false
      )
      receipt.receipt_items.create!(
        confirmed_name: '外税商品B',
        price: 3_687,
        quantity: 1,
        quantity_unit_code: 'each',
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

    it 'quantity_unit_codeを編集できるselectを表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit_code: 'kilogram',
        line_total: 4_320,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_unit_options = document.css('select[name$="[quantity_unit_code]"] option')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('quantity_unit_code')
        expect(response.body).to include('kilogram')
        expect(quantity_unit_options.map(&:text)).to include('kg')
        expect(quantity_unit_options.map(&:text)).not_to include('その他')
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
        quantity_unit_code: 'each',
        line_total: 310,
        needs_review: false,
        review_reasons: []
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      warning_card = document.at_css('[data-receipt-warning-notes-card]')
      target_link = warning_card.at_css('a[data-review-reason-target-link][data-review-reason-code="price_tax_inclusion_uncertain"]')
      target_link_layout = target_link&.parent
      item_name_input = document.at_css('input[value="通常商品"]')
      item_row = item_name_input.ancestors.find { |node| node['data-receipt-form-target'].to_s == 'itemRow' }
      item_details_panel = item_row.at_css('[data-receipt-form-target="itemDetailsPanel"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(response.body).to include('確認情報')
        expect(response.body).to include('金額整合性')
        expect(response.body).to include('明細金額が税込か税抜かを一意に判定できない箇所があります。必要に応じて小計・税額をご確認ください。')
        expect(response.body).not_to include('要確認内容')
        expect(target_link).to be_present
        expect(target_link['class']).to include('btn-link-warning')
        expect(target_link['class']).to include('ui-touch-control')
        expect(target_link_layout['class']).to include('flex-col')
        expect(target_link_layout['class']).to include('sm:flex-row')
        expect(target_link['data-turbo']).to eq('false')
        expect(target_link['href']).to eq("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY}")
        expect(target_link['data-review-reason-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY)
        expect(target_link['data-review-reason-anchor-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY)
        expect(item_details_panel.at_css('.receipt-form-item-warning-notes')).to be_nil
      end
    end

    it 'receipt-level reviewを編集画面で折りたたみ表示する' do
      receipt.update!(
        status: 'review_needed',
        review_reasons: [ 'tax_detail_mismatch' ]
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      review_card = document.at_css('[data-receipt-review-notes-card]')
      summary = review_card.at_css('[data-receipt-notes-summary]')
      details = review_card.at_css('[data-receipt-notes-details]')
      target_link = review_card.at_css('a[data-review-reason-target-link][data-review-reason-code="tax_detail_mismatch"]')
      target_link_layout = target_link&.parent

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(review_card).to be_present
        expect(review_card['open']).to be_nil
        expect(review_card['class']).to include('min-w-0')
        expect(summary['class']).to include('min-w-0')
        expect(details['class']).to include('min-w-0')
        expect(summary.text).to include('要確認内容', '1件')
        expect(details.text).to include('金額整合性', '税内訳と明細の税額が一致していません')
        expect(target_link).to be_present
        expect(target_link['class']).to include('btn-link-danger')
        expect(target_link['class']).to include('shrink-0')
        expect(target_link_layout['class']).to include('flex-col')
        expect(target_link_layout['class']).to include('sm:flex-row')
        expect(target_link['data-turbo']).to eq('false')
        expect(target_link['href']).to eq("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY}")
        expect(target_link['data-review-reason-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY)
        expect(target_link['data-review-reason-anchor-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY)
        expect(document.at_css("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_BASIC_INFO}")).to be_present
        expect(document.at_css("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS}")).to be_present
        expect(document.at_css("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ADJUSTMENTS}")).to be_present
        expect(document.at_css("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_PAYMENTS}")).to be_present
        expect(document.at_css("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_AMOUNT_SUMMARY}")).to be_present
        expect(document.at_css("##{ReceiptsHelper::RECEIPT_REVIEW_TARGET_IMAGE_PREVIEW}")).to be_present
      end
    end

    it '明細ごとのreview reasonは編集画面で該当明細行anchorを持つ' do
      review_item = receipt.receipt_items.create!(
        confirmed_name: '要確認商品',
        price: 310,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 310,
        needs_review: true,
        review_reasons: [ 'item_tax_rate_uncertain' ]
      )

      receipt.update!(status: 'review_needed', review_reasons: [])

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      target_id = "#{ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEM_ID_PREFIX}#{review_item.id}"
      item_row = document.at_css("##{target_id}")
      target_link = document.at_css("a[data-review-reason-target-item='#{target_id}']")
      item_details_panel = item_row.at_css('[data-receipt-form-target="itemDetailsPanel"]')
      template_html = document.at_css('template[data-receipt-form-target="template"]')&.inner_html.to_s

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(item_row).to be_present
        expect(item_row['data-receipt-review-item-row']).to eq('true')
        expect(item_details_panel['aria-hidden']).to eq('true')
        expect(item_details_panel['class']).not_to include('is-open')
        expect(target_link).to be_present
        expect(target_link['data-turbo']).to eq('false')
        expect(target_link['href']).to eq("##{target_id}")
        expect(target_link['data-review-reason-target']).to eq(ReceiptsHelper::RECEIPT_REVIEW_TARGET_ITEMS)
        expect(target_link['data-review-reason-anchor-target']).to eq(target_id)
        expect(template_html).not_to include('data-receipt-review-item-row="true"')
        expect(template_html).not_to include('id="receipt-item-')
      end
    end

    it '明細行とNEW_RECORDテンプレートのStimulus接続を維持する' do
      receipt.receipt_items.create!(
        confirmed_name: '接続確認商品',
        price: 310,
        quantity: 1,
        quantity_unit_code: 'each',
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
        expect(form['data-receipt-form-delete-confirmation-enabled-value']).to eq('true')
        expect(form['data-receipt-form-countable-quantity-units-value']).to eq('each,item,piece,bag,sheet,unit,box,set')
        expect(form['data-receipt-form-decimal-quantity-units-value']).to eq('gram,kilogram,milligram,liter,milliliter,cubic_centimeter')
        expect(form['data-receipt-form-default-quantity-unit-value']).to eq('each')
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
        discount_rate_wrapper = item_details_panel.at_css('[data-receipt-form-target="discountRateInput"]').ancestors.find { |node| node['class'].to_s.include?('md:col-span-') }
        tax_rate_wrapper = item_details_panel.at_css('[data-receipt-form-target="taxRateInput"]').ancestors.find { |node| node['class'].to_s.include?('md:col-span-') }
        category_wrapper = item_details_panel.at_css('select[name$="[category]"]').ancestors.find { |node| node['class'].to_s.include?('md:col-span-') }
        subtotal_wrapper = item_details_panel.at_css('.receipt-form-item-detail-subtotal')
        subtotal_inner = subtotal_wrapper.at_css('.space-y-2')
        subtotal_box = subtotal_wrapper.at_css('[data-receipt-form-target="lineTotalDisplay"]').ancestors.find { |node| node['class'].to_s.include?('h-10') }
        mobile_summary = item_row.at_css('.receipt-form-item-mobile-summary')
        swipe_wrapper = item_row.ancestors.find { |node| node['data-controller'].to_s.include?('swipe-action') }

        expect(item_details_toggle['data-action']).to include('click->receipt-form#toggleItemDetails')
        expect(item_details_toggle['aria-expanded']).to eq('false')
        expect(item_details_panel['class']).to include('collapsible-grid')
        expect(item_details_panel['class']).not_to include('is-open')
        expect(item_details_panel['aria-hidden']).to eq('true')
        expect(item_details_panel.has_attribute?('inert')).to be(true)
        expect(item_details_panel.at_css('[data-receipt-form-target="discountRateInput"]')).to be_present
        expect(item_details_panel.at_css('[data-receipt-form-target="taxRateInput"]')).to be_present
        expect(item_details_panel.at_css('[data-receipt-form-target="lineTotalDisplay"]')).to be_present
        expect(item_details_panel.at_css('select[name$="[category]"]')).to be_present
        expect(discount_rate_wrapper['class']).to include('md:col-span-3')
        expect(tax_rate_wrapper['class']).to include('md:col-span-3')
        expect(category_wrapper['class']).to include('md:col-span-3')
        expect(subtotal_wrapper['class']).to include('md:col-span-3')
        expect(subtotal_wrapper['class']).to include('md:items-start')
        expect(subtotal_inner['class']).to include('w-full')
        expect(subtotal_box['class']).to include('h-10')
        expect(subtotal_box['class']).not_to include('md:max-w-[280px]')
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
        expect(swipe_wrapper).to be_present
        expect(swipe_wrapper.at_css('[data-swipe-action-target="foreground"]')).to be_present
        expect(swipe_wrapper.at_css('.swipe-action-background [data-action*="receipt-form#removeItem"][data-swipe-action-target="action"]')).to be_present
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
        quantity_input = item_row.at_css('[data-receipt-form-target="quantityInput"]')
        expect(quantity_input['data-action']).to eq('input->receipt-form#recalculate')
        expect(quantity_unit_select['data-action']).to include('change->receipt-form#quantityUnitChanged')
        expect(quantity_unit_select['aria-label']).to eq(I18n.t('receipts.item_fields.unit'))
        expect(quantity_input['step']).to eq('1')
        expect(quantity_input['inputmode']).to eq('numeric')
        expect(item_row.at_css(%(button[aria-label="#{I18n.t('shared.number_field.decrement_aria', label: I18n.t('receipts.item_fields.unit_price'))}"]))).to be_present
        expect(item_row.at_css(%(button[aria-label="#{I18n.t('shared.number_field.increment_aria', label: I18n.t('receipts.item_fields.unit_price'))}"]))).to be_present

        line_total_input = item_row.at_css('[data-receipt-form-target="lineTotalInput"]')
        expect(line_total_input['data-original-line-total']).to eq('310')
        expect(template_html).to include('data-receipt-form-target="originalLineTotalInput"')

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
        quantity_unit_code: 'each',
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
          quantity_unit_code: quantity.frac.zero? ? 'each' : 'kilogram',
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
        quantity_unit_code: 'each',
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
        quantity_unit_code: 'each',
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
        quantity_unit_code: 'each',
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
        quantity_unit_code: 'each',
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
        expect(line_total_input['data-original-saved-line-total']).to eq('895')
        expect(controller_source).to include('shouldPreserveExistingLineTotal')
        expect(controller_source).to include('discountRateWasEdited')
        expect(controller_source).to include('preservedLineTotalInputValue')
        expect(controller_source).to include('originalSavedLineTotal')
      end
    end

    it '新規明細行には保存済みline_total保持用のdata属性を出さない' do
      get new_receipt_path

      document = Nokogiri::HTML(response.body)
      line_total_input = document.at_css('template input[name$="[line_total]"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(line_total_input['data-receipt-form-target']).to eq('lineTotalInput')
        expect(line_total_input['data-original-line-total']).to be_nil.or eq('')
        expect(line_total_input['data-original-saved-line-total']).to be_nil
      end
    end

    it '数量入力も入力途中の値を共通コントローラで補正しない' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit_code: 'kilogram',
        line_total: 4_320,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_input = document.at_css('[data-receipt-form-target="quantityInput"]')
      price_input = document.at_css('[data-receipt-form-target="priceInput"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_input['data-action']).to eq('input->receipt-form#recalculate')
        expect(price_input['data-action']).to eq('input->receipt-form#recalculate')
      end
    end

    it '数量単位selectを再計算判定targetとして表示し、unit変更時にstep同期と再計算を行う' do
      receipt.receipt_items.create!(
        confirmed_name: '量り売り商品',
        price: 14_400,
        quantity: BigDecimal('0.300'),
        quantity_unit_code: 'kilogram',
        line_total: 4_320,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_unit_select = document.at_css('select[name$="[quantity_unit_code]"]')
      quantity_input = document.at_css('[data-receipt-form-target="quantityInput"]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_unit_select['data-receipt-form-target']).to eq('quantityUnitInput')
        expect(quantity_unit_select['data-action']).to include('change->receipt-form#quantityUnitChanged')
        expect(quantity_input['data-action']).to eq('input->receipt-form#recalculate')
        expect(quantity_input['step']).to eq('0.001')
        expect(quantity_input['inputmode']).to eq('decimal')
      end
    end

    it 'measurement unitへ変更後も後続再計算で新規明細の算出済み小計を保持できるJS同期を持つ' do
      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      template_html = document.at_css('template[data-receipt-form-target="template"]')&.inner_html.to_s
      controller_source = Rails.root.join('app/javascript/controllers/receipt_form_controller.js').read

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(template_html).to include('data-receipt-form-target="originalLineTotalInput"')
        expect(template_html).to include('data-receipt-form-target="quantityUnitInput"')
        expect(template_html).to include('change-&gt;receipt-form#quantityUnitChanged')
        expect(template_html).not_to include('change-&gt;receipt-form#recalculate')
        expect(controller_source).to include('syncLineTotalState')
        expect(controller_source).to include('lineTotalInput.dataset.workingOriginalLineTotal = String(originalLineTotal)')
        expect(controller_source).to include('originalLineTotalInput.value = originalLineTotal')
      end
    end

    it 'countable unitとmeasurement unitを選択肢として表示する' do
      receipt.receipt_items.create!(
        confirmed_name: '単位確認商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      option_values = document.css('select[name$="[quantity_unit_code]"] option').map { |option| option['value'] }.uniq
      controller_source = Rails.root.join('app/javascript/controllers/receipt_form_controller.js').read

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(option_values).to include('each', 'item', 'piece', 'bag', 'sheet', 'unit', 'box', 'set')
        expect(option_values).to include('kilogram', 'gram', 'milligram', 'liter', 'milliliter', 'cubic_centimeter')
        expect(controller_source).to include('countableQuantityUnitsValue')
        expect(controller_source).not_to include("['個', '点', '本', '袋', '枚', '台', '箱', 'セット']")
      end
    end

    it '未知単位は候補外値を選択肢として保持しない' do
      receipt.receipt_items.create!(
        confirmed_name: '未知単位商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: false
      )

      get edit_receipt_path(receipt)

      document = Nokogiri::HTML(response.body)
      quantity_unit_select = document.at_css('select[name$="[quantity_unit_code]"]')
      selected_option = quantity_unit_select.at_css('option[selected]')

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(quantity_unit_select.css('option').map { |option| option['value'] }).not_to include('束')
        expect(selected_option['value']).to eq('each')
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

  describe 'PATCH /receipts/:public_id' do
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

    def patch_receipt(receipt, params:)
      submitted_params = params.deep_dup
      receipt_params = submitted_params[:receipt] || submitted_params['receipt']
      if receipt_params && !receipt_params.key?(:lock_version) && !receipt_params.key?('lock_version')
        receipt_params[:lock_version] = receipt.lock_version
      end

      patch receipt_path(receipt), params: submitted_params
    end

    it 'レシートを更新できる' do
      patch_receipt receipt, params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.store_name).to eq('更新後')
        expect(receipt.total_amount).to eq(2000)
        expect(receipt.payment_method).to eq('credit_card')
        expect(receipt.memo).to eq('更新メモ')
        expect(receipt.amount_calculation_profile).to include(
          'context' => 'edit_save',
          'resolved' => include('total_amount' => 2000)
        )
      end
    end

    it '隔離中のレシートは更新できず、画像削除も実行しない' do
      quarantined_receipt = create(:receipt, :quarantined, :with_image, user: user, status: 'review_needed')
      blob_id = quarantined_receipt.image.blob.id

      expect do
        patch receipt_path(quarantined_receipt),
              params: { receipt: { store_name: '更新されない', remove_image: '1' } }
      end.not_to change { quarantined_receipt.reload.store_name }

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(quarantined_receipt.image).to be_attached
        expect(ActiveStorage::Blob.exists?(blob_id)).to be(true)
      end
    end

    it '更新ではmanual receipt counterを消費しない' do
      create(:usage_counter, user: user, key: 'manual_receipts_per_day', used_count: 50)

      patch_receipt receipt, params: valid_update_params

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(50)
      end
    end

    it '明細パラメータがない通常編集は既存明細があれば保存できる' do
      item = receipt.receipt_items.create!(
        confirmed_name: '既存商品',
        price: 700,
        quantity: 2,
        quantity_unit_code: 'each',
        line_total: 1400,
        needs_review: false
      )

      patch_receipt receipt, params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.store_name).to eq('更新後')
        expect(receipt.receipt_items).to contain_exactly(item)
      end
    end

    it '明細数がuser limitを超える手動更新を金額計算前に拒否する' do
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 1 })
      item = receipt.receipt_items.create!(
        confirmed_name: '既存商品',
        price: 700,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 700,
        needs_review: false
      )
      params = {
        receipt: {
          store_name: '更新後',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              line_total: item.line_total,
              needs_review: false
            },
            '1' => manual_item_params(1)
          }
        }
      }
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        patch_receipt receipt, params: params
      end.not_to change { receipt.reload.receipt_items.count }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('明細は1件まで登録できます')
        expect(receipt.reload.store_name).to eq('更新前')
      end
    end

    it 'override上限内の150件の手動更新を許可する' do
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 200 })
      params = {
        receipt: {
          store_name: '更新後',
          total_amount: 15_000,
          payment_method: 'cash',
          receipt_items_attributes: manual_items_params(150)
        }
      }

      patch_receipt receipt, params: params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.store_name).to eq('更新後')
        expect(receipt.receipt_items.count).to eq(150)
      end
    end

    it 'override上限を超える201件の手動更新を金額計算前に拒否する' do
      create(:user_limit_override, user: user, key: 'receipt_items_per_receipt', value: { 'value' => 200 })
      params = {
        receipt: {
          store_name: '更新後',
          total_amount: 20_100,
          payment_method: 'cash',
          receipt_items_attributes: manual_items_params(201)
        }
      }
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        patch_receipt receipt, params: params
      end.not_to change { receipt.reload.receipt_items.count }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('明細は200件まで登録できます')
        expect(receipt.reload.store_name).to eq('更新前')
      end
    end

    it '金額上限を超える手動更新を金額計算前に拒否する' do
      receipt
      create(:system_setting, key: 'limits.receipt_item_price_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_item_line_total_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_tax_amount_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_adjustment_amount_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_payment_amount_max', value: SystemSettings.stored_value(500))
      create(:system_setting, key: 'limits.receipt_total_amount_max', value: SystemSettings.stored_value(500))
      expect(ReceiptAmountService).not_to receive(:call)

      expect do
        patch_receipt receipt, params: { receipt: { store_name: '更新後' } }
      end.not_to change { receipt.reload.updated_at }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include('receipt.total_amount は500以下で入力してください')
        expect(receipt.reload.store_name).to eq('更新前')
      end
    end

    it 'direct paramsでmanual adjustmentを更新できる' do
      item = receipt.receipt_items.create!(
        confirmed_name: '既存商品',
        price: 1000,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1000,
        needs_review: false
      )
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'delivery_fee',
        label: '旧配送料',
        amount: 100,
        sign: 'surcharge',
        tax_rate: BigDecimal('0.1'),
        source: 'ai',
        needs_review: true,
        review_reasons: [ 'adjustment_uncertain' ],
        position_index: 0
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '更新後',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              tax_rate: 10,
              line_total: item.line_total,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              id: adjustment.id,
              kind: 'delivery_fee',
              label: '新配送料',
              amount: '220',
              sign: 'surcharge',
              tax_rate: '10',
              position_index: '2'
            }
          }
        }
      }
      receipt.reload
      adjustment.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(1220)
        expect(adjustment.label).to eq('新配送料')
        expect(adjustment.amount).to eq(220)
        expect(adjustment.source).to eq('manual')
        expect(adjustment.needs_review).to be(false)
        expect(adjustment.review_reasons).to eq([])
      end
    end

    it 'direct paramsでadjustmentを削除できる' do
      item = receipt.receipt_items.create!(
        confirmed_name: '既存商品',
        price: 1000,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1000,
        needs_review: false
      )
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'delivery_fee',
        label: '配送料',
        amount: 220,
        sign: 'surcharge',
        tax_rate: BigDecimal('0.1'),
        source: 'manual',
        needs_review: false,
        position_index: 0
      )

      expect do
        patch_receipt receipt, params: {
          receipt: {
            store_name: '削除後',
            receipt_items_attributes: {
              '0' => {
                id: item.id,
                confirmed_name: item.confirmed_name,
                price: item.price,
                quantity: item.quantity,
                quantity_unit_code: item.quantity_unit_code,
                tax_rate: 10,
                line_total: item.line_total,
                needs_review: false
              }
            },
            receipt_adjustments_attributes: {
              '0' => {
                id: adjustment.id,
                _destroy: '1'
              }
            }
          }
        }
      end.to change(ReceiptAdjustment, :count).by(-1)

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.receipt_adjustments).to be_empty
        expect(receipt.total_amount).to eq(1000)
      end
    end

    it 'adjustment未送信の通常編集では既存adjustmentを消さない' do
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'delivery_fee',
        label: '配送料',
        amount: 220,
        sign: 'surcharge',
        source: 'manual',
        needs_review: false
      )

      patch_receipt receipt, params: valid_update_params

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.reload.receipt_adjustments).to contain_exactly(adjustment)
      end
    end

    it 'direct paramsでpayment rowsを更新・追加・削除できる' do
      receipt.update!(total_amount: 1_200, subtotal_amount: 1_100, tax_amount: 100)
      cash = receipt.receipt_payments.create!(method: '現金', amount: 1_000)
      old_payment = receipt.receipt_payments.create!(method: '旧支払', amount: 200)

      patch_receipt receipt, params: {
        receipt: {
          store_name: '支払更新後',
          receipt_payments_attributes: {
            '0' => {
              id: cash.id,
              method: '現金',
              amount: '500'
            },
            '1' => {
              id: old_payment.id,
              _destroy: '1'
            },
            '2' => {
              method: '電子マネー',
              amount: '700'
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        # 検算: 支払合計 500 + 700 = 1,200。購入合計/実支払額 1,200 と一致する。
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.receipt_payments.order(:id).pluck(:method, :amount)).to eq([
          [ '現金', 500 ],
          [ '電子マネー', 700 ]
        ])
        expect(receipt.amount_calculation_profile.dig('computed', 'payment_amount_sum')).to eq(1_200)
        expect(receipt.review_reasons).not_to include('payment_amount_mismatch')
      end
    end

    it 'サービス料追加後に支払額が旧金額のままならpayment_amount_mismatchにする' do
      receipt.update!(store_name: 'サービス料追加前', total_amount: 1_000, subtotal_amount: 910, tax_amount: 90, status: 'completed')
      item = receipt.receipt_items.create!(
        confirmed_name: '商品A',
        price: 1_000,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_000,
        needs_review: false
      )
      payment = receipt.receipt_payments.create!(method: '現金', amount: 1_000)

      patch_receipt receipt, params: {
        receipt: {
          store_name: 'サービス料追加後',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              tax_rate: 10,
              line_total: item.line_total,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'service_charge',
              label: 'サービス料',
              amount: '100',
              sign: 'surcharge',
              tax_rate: '10'
            }
          },
          receipt_payments_attributes: {
            '0' => {
              id: payment.id,
              method: payment.method,
              amount: '1000'
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        # 検算: 商品 1,000 + サービス料 100 = 実支払額 1,100。支払 1,000 なので100円不足。
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(1_100)
        expect(receipt.amount_calculation_profile.dig('computed', 'final_payment_total')).to eq(1_100)
        expect(receipt.amount_calculation_profile.dig('computed', 'payment_amount_sum')).to eq(1_000)
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
        expect(receipt.status).to eq('review_needed')
      end
    end

    it 'native engineでもサービス料追加後の支払不足をreview reasonへ投影する' do
      receipt.update!(store_name: 'native engine サービス料追加前', total_amount: 1_000, subtotal_amount: 910, tax_amount: 90, status: 'completed')
      item = receipt.receipt_items.create!(
        confirmed_name: '商品A',
        price: 1_000,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_000,
        needs_review: false
      )
      payment = receipt.receipt_payments.create!(method: '現金', amount: 1_000)

      patch_receipt receipt, params: {
        receipt: {
          store_name: 'native engine サービス料追加後',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              tax_rate: 10,
              line_total: item.line_total,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'service_charge',
              label: 'サービス料',
              amount: '100',
              sign: 'surcharge',
              tax_rate: '10'
            }
          },
          receipt_payments_attributes: {
            '0' => {
              id: payment.id,
              method: payment.method,
              amount: '1000'
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        # 検算: 商品 1,000 + サービス料 100 = 実支払額 1,100。支払 1,000 なので100円不足。
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(1_100)
        expect(receipt.amount_calculation_profile.dig('computed', 'final_payment_total')).to eq(1_100)
        expect(receipt.amount_calculation_profile.dig('computed', 'payment_amount_sum')).to eq(1_000)
        expect(receipt.amount_calculation_profile.dig('amount_engine', 'selected_basis')).to eq('items_as_tax_included')
        expect(receipt.review_reasons).to include('payment_amount_mismatch')
        expect(receipt.status).to eq('review_needed')
      end
    end

    it 'サービス料追加後に支払額も直せばpayment_amount_mismatchにしない' do
      receipt.update!(store_name: 'サービス料修正前', total_amount: 1_000, subtotal_amount: 910, tax_amount: 90, status: 'completed')
      item = receipt.receipt_items.create!(
        confirmed_name: '商品A',
        price: 1_000,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_000,
        needs_review: false
      )
      payment = receipt.receipt_payments.create!(method: '現金', amount: 1_000)

      patch_receipt receipt, params: {
        receipt: {
          store_name: 'サービス料修正後',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              tax_rate: 10,
              line_total: item.line_total,
              needs_review: false
            }
          },
          receipt_adjustments_attributes: {
            '0' => {
              kind: 'service_charge',
              label: 'サービス料',
              amount: '100',
              sign: 'surcharge',
              tax_rate: '10'
            }
          },
          receipt_payments_attributes: {
            '0' => {
              id: payment.id,
              method: payment.method,
              amount: '1100'
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        # 検算: 商品 1,000 + サービス料 100 = 実支払額 1,100。支払 1,100 と一致する。
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.total_amount).to eq(1_100)
        expect(receipt.amount_calculation_profile.dig('computed', 'final_payment_total')).to eq(1_100)
        expect(receipt.amount_calculation_profile.dig('computed', 'payment_amount_sum')).to eq(1_100)
        expect(receipt.review_reasons).not_to include('payment_amount_mismatch')
      end
    end

    it '通知OFFなら更新成功のredirect flashを表示しない' do
      user.update!(push_notification_enabled: false)

      patch_receipt receipt, params: valid_update_params

      follow_redirect!
      document = Nokogiri::HTML(response.body)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(document.at_css('#flash [data-controller~="notice-surface"]')).to be_nil
        expect(response.body).not_to include(I18n.t('flash.receipts.update'))
      end
    end

    it '不正なパラメータでは更新できない' do
      patch_receipt receipt, params: invalid_update_params
      receipt.reload

      aggregate_failures do
        expect([ 200, 422 ]).to include(response.status)
        expect(receipt.store_name).to eq('更新前')
        expect(receipt.total_amount).to eq(1400)
      end
    end

    it 'hidden needs_review=false を送っても未修正itemのreviewは消えない' do
      receipt.update!(status: 'review_needed', review_reasons: [])
      item = receipt.receipt_items.create!(
        confirmed_name: '未修正商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: true,
        review_reasons: [ 'item_name_uncertain' ]
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: receipt.store_name,
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              tax_rate: '',
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
        expect(item.needs_review).to be(true)
        expect(item.review_reasons).to eq([ 'item_name_uncertain' ])
        expect(receipt.status).to eq('review_needed')
      end
    end

    it 'hidden review_reasons=[] を送っても未修正itemのreviewは消えない' do
      receipt.update!(status: 'review_needed', review_reasons: [])
      item = receipt.receipt_items.create!(
        confirmed_name: '理由未修正商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: true,
        review_reasons: [ 'item_category_uncertain' ]
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: receipt.store_name,
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              tax_rate: '',
              line_total: item.line_total,
              review_reasons: []
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.needs_review).to be(true)
        expect(item.review_reasons).to eq([ 'item_category_uncertain' ])
        expect(receipt.status).to eq('review_needed')
      end
    end

    it '保護属性を送ってもstatusやAmount Engine内部contractは保存されない' do
      receipt.update!(
        status: 'review_needed',
        review_reasons: [ 'tax_detail_mismatch' ],
        subtotal_amount: receipt.total_amount,
        tax_amount: 0,
        tax_rate: BigDecimal('0'),
        amount_calculation_profile: { 'existing' => 'profile' }
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '保護属性更新',
          total_amount: receipt.total_amount,
          payment_method: 'cash',
          status: 'completed',
          review_reasons: [],
          amount_calculation_profile: { forged: 'forged-profile' },
          safe_to_auto_complete: 'forged-safe',
          selected_candidate_status: 'forged-selected-status'
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to eq([ 'tax_detail_mismatch' ])
        expect(receipt.amount_calculation_profile.to_json).not_to include(
          'forged-profile',
          'forged-safe',
          'forged-selected-status'
        )
      end
    end

    it 'item raw_textを送っても保存されない' do
      item = receipt.receipt_items.create!(
        raw_text: 'OCR原文',
        confirmed_name: '保護属性商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: 'raw_text保護属性更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              raw_text: 'FORGED_RAW_TEXT',
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: item.quantity_unit_code,
              tax_rate: '',
              line_total: item.line_total
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.raw_text).to eq('OCR原文')
      end
    end

    it '画像差し替えを含むvalidation失敗時もsigned_id errorにならず編集フォームに戻る' do
      patch_receipt receipt, params: {
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
      allow(ReceiptOcrJob).to receive(:perform_later)

      patch_receipt receipt, params: {
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
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it '画像差し替え時だけ現在のuser画像保持設定で再snapshotする' do
      receipt.update!(
        keep_image: true,
        image_purge_eligible_at: 1.day.ago,
        image_purged_at: 1.hour.ago,
        image_purged_reason: Receipt::IMAGE_PURGED_REASON_SYSTEM_PURGE
      )
      user.update!(keep_receipt_images: false)

      patch_receipt receipt, params: {
        receipt: {
          store_name: '画像差し替え保持OFF',
          total_amount: 2100,
          payment_method: 'cash',
          image: uploaded_image
        }
      }
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.keep_image).to be(false)
        expect(receipt.image_purge_eligible_at).to be_present
        expect(receipt.image_purged_at).to be_nil
        expect(receipt.image_purged_reason).to be_nil
      end
    end

    it '画像差し替え時は解析失敗処理も実行しない' do
      allow(ReceiptOcrJob).to receive(:perform_later)

      patch_receipt receipt, params: {
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
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
        expect(receipt.processing_error_code).to be_nil
      end
    end

    it '画像差し替え時は既存blob分を差し引いて容量判定する' do
      receipt.image.attach(uploaded_image)
      user.update!(storage_limit_bytes: receipt.image.blob.byte_size)

      patch_receipt receipt, params: {
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

      patch_receipt receipt, params: {
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

    it '画像差し替え時に全体storage hard stopを超える場合は更新しない' do
      allow(Storage).to receive(:global_quota_can_add?).and_return(false)

      patch_receipt receipt, params: {
        receipt: {
          store_name: '画像差し替え全体容量NG',
          total_amount: 2200,
          payment_method: 'cash',
          image: uploaded_image
        }
      }

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include(I18n.t('flash.storage.global_hard_stop'))
        expect(receipt.reload.store_name).to eq('更新前')
      end
    end

    it 'remove_image=1で既存画像を削除する' do
      receipt.image.attach(uploaded_image)
      old_blob = receipt.image.blob

      patch_receipt receipt, params: {
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
        expect(receipt.image_purged_at).to be_present
        expect(receipt.image_purged_reason).to eq(Receipt::IMAGE_PURGED_REASON_MANUAL_DELETE)
      end
    end

    it 'validation失敗時はremove_image=1でも既存画像を削除しない' do
      receipt.image.attach(uploaded_image)
      old_blob = receipt.image.blob

      patch_receipt receipt, params: {
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

      patch_receipt receipt, params: {
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

      patch_receipt receipt, params: {
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
      allow(ReceiptOcrJob).to receive(:perform_later)

      patch_receipt receipt, params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(ReceiptOcrJob).not_to have_received(:perform_later)
      end
    end

    it 'failed receipt を手動編集保存するとcompletedに戻しprocessing errorを消す' do
      receipt.update!(
        status: 'failed',
        processing_error_code: 'ocr_timeout',
        processing_error_message: 'OCR service timeout'
      )

      patch_receipt receipt, params: valid_update_params
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
      end
    end

    it 'review_needed receipt は編集保存でamount blocking reasonが解消されるとcompletedに戻る' do
      receipt.update!(
        status: 'review_needed',
        processing_error_code: 'ai_invalid_response',
        processing_error_message: 'AI response invalid',
        review_reasons: [ 'tax_detail_mismatch' ]
      )
      item = receipt.receipt_items.create!(
        confirmed_name: '修正済み商品',
        price: 110,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 110,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '確認済みレシート',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '修正済み商品',
              price: 110,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: 110,
              needs_review: false
            }
          }
        }
      }
      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('completed')
        expect(receipt.processing_error_code).to be_nil
        expect(receipt.processing_error_message).to be_nil
        expect(receipt.review_reasons).to be_empty
        expect(Receipts::SummaryQuery.call(user: user).review_needed_count).to eq(0)
        expect(Receipts::SummaryQuery.call(user: user).failed_count).to eq(0)
      end
    end

    it 'item_total_mismatch を修正するとreview_reasonsから消える' do
      receipt.update!(status: 'review_needed', review_reasons: [ 'item_total_mismatch' ])
      item = receipt.receipt_items.create!(
        confirmed_name: '修正前商品',
        price: 100,
        quantity: 2,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '明細整合レシート',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '修正後商品',
              price: 100,
              quantity: 2,
              quantity_unit_code: 'each',
              tax_rate: '',
              line_total: 200,
              needs_review: false
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).not_to include('item_total_mismatch')
        expect(receipt.total_amount).to eq(200)
      end
    end

    it 'tax_amount_mismatch を修正するとreview_reasonsから消える' do
      receipt.update!(status: 'review_needed', review_reasons: [ 'tax_amount_mismatch' ])
      item = receipt.receipt_items.create!(
        confirmed_name: '税込商品',
        price: 108,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.08'),
        line_total: 108,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '税額整合レシート',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '税込商品',
              price: 108,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 8,
              line_total: 108,
              needs_review: false
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).not_to include('tax_amount_mismatch')
        expect(receipt.tax_amount).to eq(8)
      end
    end

    it 'tax_detail_mismatch を修正すると旧税内訳を再構築してcompletedに戻る' do
      receipt.update!(status: 'review_needed', review_reasons: [ 'tax_detail_mismatch' ])
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.08'),
        net_amount: 100,
        amount: 99,
        description: '不整合な税内訳'
      )
      item = receipt.receipt_items.create!(
        confirmed_name: '税内訳商品',
        price: 108,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.08'),
        line_total: 108,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '税内訳整合レシート',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '税内訳商品',
              price: 108,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 8,
              line_total: 108,
              needs_review: false
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).not_to include('tax_detail_mismatch')
        expect(receipt.receipt_tax_details.count).to eq(1)
        expect(receipt.receipt_tax_details.first.amount).to eq(8)
      end
    end

    it 'warning-only mismatch はreview_reasonsへ残さずamount_calculation_profile.warningsへ残す' do
      receipt.update!(status: 'review_needed', review_reasons: [ 'price_tax_inclusion_uncertain' ])
      item = receipt.receipt_items.create!(
        confirmed_name: '0円確認商品',
        price: nil,
        quantity: nil,
        quantity_unit_code: 'each',
        line_total: 0,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: 'warning確認レシート',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '0円確認商品',
              price: '',
              quantity: '',
              quantity_unit_code: 'each',
              tax_rate: '',
              line_total: 0,
              needs_review: false
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_empty
        expect(receipt.amount_calculation_profile.fetch('warnings')).to include('zero_amount_item_incomplete')
      end
    end

    it 'item-level needs_review を編集で解消するとreceiptもcompletedに戻る' do
      receipt.update!(status: 'review_needed', review_reasons: [])
      item = receipt.receipt_items.create!(
        confirmed_name: '未確定商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: true,
        review_reasons: [ 'item_name_uncertain' ]
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '明細確認済み',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '確認済み商品',
              price: 100,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: '',
              line_total: 100,
              needs_review: true,
              review_reasons: [ 'item_name_uncertain' ]
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.needs_review).to be(false)
        expect(item.review_reasons).to be_empty
        expect(receipt.status).to eq('completed')
        expect(receipt.review_reasons).to be_empty
      end
    end

    it 'multiple_receipts_suspected はitem編集だけでは解除しない' do
      receipt.update!(status: 'review_needed', review_reasons: [ 'multiple_receipts_suspected' ])
      item = receipt.receipt_items.create!(
        confirmed_name: '単体確認商品',
        price: 300,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 300,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '単体確認済み',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '単体確認商品',
              price: 300,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: '',
              line_total: 300,
              needs_review: false
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to include('multiple_receipts_suspected')
      end
    end

    it 'item-level needs_review が残る場合はreview_neededを維持する' do
      receipt.update!(status: 'review_needed', review_reasons: [])
      item = receipt.receipt_items.create!(
        confirmed_name: '未確認商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 100,
        needs_review: true,
        review_reasons: [ 'item_name_uncertain' ]
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: 'まだ未確認',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '未確認商品',
              price: 100,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: '',
              line_total: 100,
              needs_review: true,
              review_reasons: [ 'item_name_uncertain' ]
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.status).to eq('review_needed')
        expect(receipt.review_reasons).to be_empty
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

      patch_receipt receipt, params: {
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

    it '既存明細を0円商品へ変更した場合はhidden line_totalが古くても0円で保存する' do
      receipt.update!(
        store_name: '1円レシート',
        total_amount: 1,
        subtotal_amount: 1,
        tax_amount: 0,
        tax_rate: nil,
        status: 'completed'
      )
      item = receipt.receipt_items.create!(
        confirmed_name: '1円商品',
        price: 1,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 1,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '0円レシート',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '0円商品',
              price: 0,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: '',
              line_total: 1,
              needs_review: false
            }
          }
        }
      }

      receipt.reload
      item.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(item.confirmed_name).to eq('0円商品')
        expect(item.price).to eq(0)
        expect(item.line_total).to eq(0)
        expect(receipt.total_amount).to eq(0)
        expect(receipt.subtotal_amount).to eq(0)
        expect(receipt.tax_amount).to eq(0)
      end
    end

    it '既存明細を全削除して保存しようとすると保存せず空状態でフォームを戻す' do
      receipt.update!(
        store_name: '1円レシート',
        total_amount: 1,
        subtotal_amount: 1,
        tax_amount: 0,
        tax_rate: nil,
        status: 'completed'
      )
      item = receipt.receipt_items.create!(
        confirmed_name: '1円商品',
        price: 1,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 1,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '1円レシート',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 1,
              quantity: 1,
              quantity_unit_code: 'each',
              line_total: 1,
              needs_review: false,
              _destroy: '1'
            }
          }
        }
      }

      receipt.reload
      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(rendered_receipt_item_rows(document)).to be_empty
        expect(response.body).to include("receipt[receipt_items_attributes][destroy_#{item.id}][_destroy]")
        expect(receipt.receipt_items.count).to eq(1)
        expect(receipt.subtotal_amount).to eq(1)
        expect(receipt.tax_amount).to eq(0)
        expect(receipt.total_amount).to eq(1)
        expect(receipt.tax_rate).to be_nil
        expect(receipt.receipt_tax_details).to be_empty
      end
    end

    it '税内訳つきreceiptの既存明細を全削除しようとすると保存しない' do
      receipt.update!(
        store_name: '税内訳つき',
        subtotal_amount: 100,
        tax_amount: 10,
        total_amount: 110,
        tax_rate: BigDecimal('0.1'),
        status: 'completed'
      )
      item = receipt.receipt_items.create!(
        confirmed_name: '税込商品',
        price: 110,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 110,
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.1'),
        net_amount: 100,
        amount: 10,
        description: '10%対象'
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '税内訳つき',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 110,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: 110,
              needs_review: false,
              _destroy: '1'
            }
          }
        }
      }

      receipt.reload
      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(rendered_receipt_item_rows(document)).to be_empty
        expect(receipt.receipt_items.count).to eq(1)
        expect(receipt.subtotal_amount).to eq(100)
        expect(receipt.tax_amount).to eq(10)
        expect(receipt.total_amount).to eq(110)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(receipt.receipt_tax_details.count).to eq(1)
      end
    end

    it 'OCR/AI解析由来のcompleted receiptでも既存明細全削除は保存しない' do
      receipt.update!(
        store_name: '解析済み',
        subtotal_amount: 1_164,
        tax_amount: 116,
        total_amount: 1_280,
        tax_rate: BigDecimal('0.1'),
        status: 'completed'
      )
      create(:receipt_analysis_run, :succeeded, receipt: receipt, source: 'upload')
      item = receipt.receipt_items.create!(
        confirmed_name: '解析商品',
        price: 1_280,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_280,
        needs_review: false
      )
      receipt.receipt_tax_details.create!(
        rate: BigDecimal('0.1'),
        net_amount: 1_164,
        amount: 116,
        description: '10%対象'
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '解析済み',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 1_280,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: 1_280,
              needs_review: false,
              _destroy: '1'
            }
          }
        }
      }

      receipt.reload
      document = Nokogiri::HTML(response.body)
      notice_surface = document.at_css('#flash [data-controller~="notice-surface"]')

      aggregate_failures do
        expect(response).to have_http_status(:unprocessable_content)
        expect(notice_surface.text).to include(I18n.t('receipts.form.errors.items_required'))
        expect(rendered_receipt_item_rows(document)).to be_empty
        expect(receipt.receipt_items.count).to eq(1)
        expect(receipt.subtotal_amount).to eq(1_164)
        expect(receipt.tax_amount).to eq(116)
        expect(receipt.total_amount).to eq(1_280)
        expect(receipt.tax_rate).to eq(BigDecimal('0.1'))
        expect(receipt.receipt_tax_details.count).to eq(1)
      end
    end

    it '手動更新時にcurrent_userのrounding modeをReceiptAmountServiceへ渡す' do
      user.update!(tax_rounding_mode: 'ceil', discount_rounding_mode: 'floor')
      item = receipt.receipt_items.create!(
        confirmed_name: '丸め設定更新前',
        price: 108,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 108,
        needs_review: false
      )
      observed_kwargs = nil
      allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
        observed_kwargs = kwargs
        original.call(**kwargs)
      end

      patch_receipt receipt, params: {
        receipt: {
          store_name: '丸め設定更新後',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '丸め設定更新後商品',
              price: 108,
              quantity: 1,
              quantity_unit_code: 'each',
              tax_rate: 10,
              line_total: nil,
              needs_review: false
            }
          }
        }
      }

      receipt.reload

      aggregate_failures do
        expect(response).to redirect_to(receipt_path(receipt))
        expect(observed_kwargs[:context]).to eq(:edit_save)
        expect(observed_kwargs[:tax_rounding_mode]).to eq('ceil')
        expect(observed_kwargs[:discount_rounding_mode]).to eq('floor')
        expect(receipt.tax_amount).to eq(10)
      end
    end

    it '税込補正済み明細は編集保存でもoriginal_line_totalへ戻らず購入合計と実支払額を維持する' do
      receipt.update!(
        store_name: 'サンプルコンビニ',
        subtotal_amount: 1_066,
        tax_amount: 95,
        total_amount: 1_161,
        tax_rate: nil,
        status: 'review_needed',
        review_reasons: [ 'price_tax_inclusion_uncertain' ],
        amount_calculation_profile: {
          computed: {
            payment_adjustment_total: -22,
            final_payment_total: 1_139
          }
        }
      )
      items = [
        receipt.receipt_items.create!(confirmed_name: '手巻おにぎり辛子明太子', category: 'food', price: 140, quantity: 1, quantity_unit_code: 'each', original_line_total: 130, line_total: 140, tax_rate: BigDecimal('0.08'), needs_review: false, position_index: 0),
        receipt.receipt_items.create!(confirmed_name: '炭酸飲料 500ml', category: 'drink', price: 151, quantity: 1, quantity_unit_code: 'each', original_line_total: 140, line_total: 151, tax_rate: BigDecimal('0.08'), needs_review: false, position_index: 1),
        receipt.receipt_items.create!(confirmed_name: 'ネイルカラー サンプルPK', category: 'daily_goods', price: 330, quantity: 1, quantity_unit_code: 'each', original_line_total: 300, line_total: 330, tax_rate: BigDecimal('0.10'), needs_review: false, position_index: 2),
        receipt.receipt_items.create!(confirmed_name: '雑貨A', category: 'other', price: 490, quantity: 1, quantity_unit_code: 'each', original_line_total: 490, line_total: 490, tax_rate: BigDecimal('0.10'), needs_review: false, position_index: 3),
        receipt.receipt_items.create!(confirmed_name: '50円切手', category: 'other', price: 50, quantity: 1, quantity_unit_code: 'each', original_line_total: 50, line_total: 50, tax_rate: BigDecimal('0'), needs_review: false, position_index: 4)
      ]
      adjustment = receipt.receipt_adjustments.create!(
        kind: 'receipt_discount',
        label: 'キャッシュレス還元額',
        amount: 22,
        sign: 'discount',
        source: 'ai',
        needs_review: false,
        position_index: 0
      )
      receipt.receipt_payments.create!(method: 'nanaco支払', amount: 1_139)

      patch_receipt receipt, params: {
        receipt: {
          store_name: 'サンプルコンビニ 更新後',
          payment_method: 'e_money',
          receipt_items_attributes: items.each_with_index.to_h do |item, index|
            [
              index.to_s,
              {
                id: item.id,
                confirmed_name: item.confirmed_name,
                category: item.category,
                price: item.price,
                quantity: 1,
                quantity_unit_code: 'each',
                tax_rate: item.tax_rate.to_d * 100,
                line_total: item.line_total,
                needs_review: false
              }
            ]
          end,
          receipt_adjustments_attributes: {
            '0' => {
              id: adjustment.id,
              kind: adjustment.kind,
              label: adjustment.label,
              amount: adjustment.amount,
              sign: adjustment.sign,
              tax_rate: nil,
              position_index: 0
            }
          }
        }
      }

      receipt.reload
      payment_summary = ReceiptAmountService.payment_adjustment_summary(receipt: receipt)
      saved_items = receipt.receipt_items.order(:position_index)
      selected_candidate = receipt.amount_calculation_profile.dig('amount_engine', 'selected_candidate')

      aggregate_failures do
        # 検算: 税込明細 140 + 151 + 330 + 490 + 50 = 1,161。支払調整 -22 で実支払額 1,139。
        expect(response).to redirect_to(receipt_path(receipt))
        expect(receipt.subtotal_amount).to eq(1_066)
        expect(receipt.tax_amount).to eq(95)
        expect(receipt.total_amount).to eq(1_161)
        expect(payment_summary.payment_adjustment_total).to eq(-22)
        expect(payment_summary.final_payment_total).to eq(1_139)
        expect(saved_items.pluck(:price)).to eq([ 140, 151, 330, 490, 50 ])
        expect(saved_items.pluck(:line_total)).to eq([ 140, 151, 330, 490, 50 ])
        expect(selected_candidate['purchase_total']).to eq(1_161)
        expect(selected_candidate['final_payment_total']).to eq(1_139)
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
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.08'),
        line_total: 216,
        needs_review: false
      )
      item_b = receipt.receipt_items.create!(
        confirmed_name: '外税商品B',
        price: 3_687,
        quantity: 1,
        quantity_unit_code: 'each',
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

      patch_receipt receipt, params: {
        receipt: {
          store_name: '外税更新後',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item_a.id,
              confirmed_name: item_a.confirmed_name,
              price: 108,
              quantity: 2,
              quantity_unit_code: 'each',
              tax_rate: 8,
              line_total: 216,
              needs_review: false
            },
            '1' => {
              id: item_b.id,
              confirmed_name: item_b.confirmed_name,
              price: 3_687,
              quantity: 1,
              quantity_unit_code: 'each',
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
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 600,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '割引率更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '割引更新後商品',
              price: 300,
              quantity: 2,
              quantity_unit_code: 'each',
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

    it 'measurement unitの小数quantityとquantity_unit_codeを更新し、明示line_totalを維持できる' do
      item = receipt.receipt_items.create!(
        confirmed_name: '更新前量り売り商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 100,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '小数数量更新後',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: '更新後量り売り商品',
              price: 14_400,
              quantity: '0.300',
              quantity_unit_code: 'kilogram',
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
        expect(item.quantity_unit_code).to eq('kilogram')
        expect(item.quantity_unit_code).to eq('kilogram')
        expect(item.line_total).to eq(4_320)
      end
    end

    it 'unit変更のみのPATCHではline_totalを変えない' do
      item = receipt.receipt_items.create!(
        confirmed_name: '単位だけ変更する商品',
        price: 9_999,
        quantity: 9,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 200,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '単位だけ更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: item.quantity,
              quantity_unit_code: 'kilogram',
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
        expect(item.quantity_unit_code).to eq('kilogram')
        expect(item.quantity_unit_code).to eq('kilogram')
        expect(item.line_total).to eq(200)
        expect(receipt.total_amount).to eq(200)
      end
    end

    it 'countable unitはquantity変更でline_totalを再計算する' do
      item = receipt.receipt_items.create!(
        confirmed_name: '個数商品',
        price: 500,
        quantity: 2,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_000,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '個数商品更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 500,
              quantity: 3,
              quantity_unit_code: 'each',
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
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 1_000,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '数量空欄更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 500,
              quantity: '',
              quantity_unit_code: 'each',
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
        quantity_unit_code: 'kilogram',
        tax_rate: BigDecimal('0.1'),
        line_total: 4_320,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '量り売り更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: 14_400,
              quantity: '0.500',
              quantity_unit_code: 'kilogram',
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

    it '旧quantity_unit paramだけでは数量単位を更新しない' do
      item = receipt.receipt_items.create!(
        confirmed_name: '旧param確認商品',
        price: 100,
        quantity: 1,
        quantity_unit_code: 'each',
        tax_rate: BigDecimal('0.1'),
        line_total: 100,
        needs_review: false
      )

      patch_receipt receipt, params: {
        receipt: {
          store_name: '未知単位更新',
          payment_method: 'cash',
          receipt_items_attributes: {
            '0' => {
              id: item.id,
              confirmed_name: item.confirmed_name,
              price: item.price,
              quantity: '1',
              quantity_unit: 'kg',
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
        expect(item.quantity_unit_code).to eq('each')
        expect(item.line_total).to eq(100)
      end
    end

    it '明細なし編集保存時は入力金額を尊重する' do
      patch_receipt receipt, params: {
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

      patch_receipt other_receipt, params: valid_update_params

      expect(response).to have_http_status(:not_found)
    end

    it '他人のreceipt_item_idをnested attributesに混ぜても更新できない' do
      other_user = create(:user, email: 'update-other-item@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人明細レシート', total_amount: 800, payment_method: 'cash', status: 'completed')
      other_item = other_receipt.receipt_items.create!(
        confirmed_name: '他人商品',
        price: 800,
        quantity: 1,
        quantity_unit_code: 'each',
        line_total: 800,
        needs_review: false
      )

      expect do
        patch_receipt receipt, params: {
          receipt: {
            store_name: '不正明細更新',
            receipt_items_attributes: {
              '0' => {
                id: other_item.id,
                confirmed_name: '改ざん商品',
                price: 1,
                quantity: 1,
                quantity_unit_code: 'each',
                line_total: 1,
                _destroy: '0'
              }
            }
          }
        }
      end.not_to change { other_item.reload.attributes.slice('confirmed_name', 'price', 'line_total') }

      expect(response).to have_http_status(:not_found)
    end

    it '他人のreceipt_adjustment_idをnested attributesに混ぜても更新削除できない' do
      other_user = create(:user, email: 'update-other-adjustment@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人調整レシート', total_amount: 800, payment_method: 'cash', status: 'completed')
      other_adjustment = other_receipt.receipt_adjustments.create!(
        kind: 'delivery_fee',
        label: '他人配送料',
        amount: 100,
        sign: 'surcharge',
        source: 'manual',
        needs_review: false
      )

      expect do
        patch_receipt receipt, params: {
          receipt: {
            store_name: '不正調整更新',
            receipt_adjustments_attributes: {
              '0' => {
                id: other_adjustment.id,
                label: '改ざん配送料',
                amount: 1,
                kind: 'delivery_fee',
                sign: 'surcharge',
                _destroy: '1'
              }
            }
          }
        }
      end.not_to change { ReceiptAdjustment.exists?(other_adjustment.id) }

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(other_adjustment.reload.label).to eq('他人配送料')
      end
    end

    it '他人のreceipt_payment_idをnested attributesに混ぜても更新削除できない' do
      other_user = create(:user, email: 'update-other-payment@example.com')
      other_receipt = create(:receipt, user: other_user, store_name: '他人支払レシート', total_amount: 800, payment_method: 'cash', status: 'completed')
      other_payment = other_receipt.receipt_payments.create!(method: 'cash', amount: 800)

      expect do
        patch_receipt receipt, params: {
          receipt: {
            store_name: '不正支払更新',
            receipt_payments_attributes: {
              '0' => {
                id: other_payment.id,
                method: 'credit_card',
                amount: 1,
                _destroy: '1'
              }
            }
          }
        }
      end.not_to change { ReceiptPayment.exists?(other_payment.id) }

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(other_payment.reload.amount).to eq(800)
        expect(other_payment.method).to eq('cash')
      end
    end

    context '未ログイン時' do
      before do
        sign_out user
      end

      it 'ログイン画面へリダイレクトされる' do
        patch_receipt receipt, params: valid_update_params

        expect(response).to redirect_to(new_user_session_path)
      end
    end
  end

  describe 'DELETE /receipts/:public_id' do
    let!(:receipt) do
      create(:receipt, user: user, store_name: '削除対象', total_amount: 1500, payment_method: 'cash', status: 'completed')
    end

    it 'レシートを削除できる' do
      expect do
        delete receipt_path(receipt)
      end.to change(Receipt, :count).by(-1)

      expect(response).to redirect_to(receipts_path)
    end

    it 'purge jobをenqueueできなくても削除画像のblob/fileを残さない' do
      receipt.image.attach(uploaded_image)
      blob = receipt.image.blob
      allow(ActiveStorage::PurgeJob).to receive(:perform_later).and_return(false)

      delete receipt_path(receipt)

      aggregate_failures do
        expect(response).to redirect_to(receipts_path)
        expect(ActiveStorage::Blob).not_to exist(blob.id)
        expect(blob.service).not_to exist(blob.key)
      end
    end

    it '隔離中のレシートは削除できない' do
      quarantined_receipt = create(:receipt, :quarantined, :with_image, user: user, status: 'completed')
      blob_id = quarantined_receipt.image.blob.id

      expect do
        delete receipt_path(quarantined_receipt)
      end.not_to change(Receipt, :count)

      aggregate_failures do
        expect(response).to have_http_status(:not_found)
        expect(quarantined_receipt.reload.image).to be_attached
        expect(ActiveStorage::Blob.exists?(blob_id)).to be(true)
      end
    end

    it 'stuck processing cleanupでfailed化されたレシートを削除できる' do
      stuck_receipt = create(:receipt, :with_image, :processing, user: user)
      stuck_receipt.update_columns(updated_at: 7.hours.ago)
      Receipts::Processing.cleanup_stale(cutoff: 6.hours.ago, dry_run: false)

      expect(stuck_receipt.reload.status).to eq('failed')

      expect do
        delete receipt_path(stuck_receipt)
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
