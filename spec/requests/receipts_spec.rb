require 'rails_helper'

RSpec.describe 'Receipts', type: :request do
  let(:user) { create(:user) }
  let(:image_path) { Rails.root.join('spec/fixtures/files/receipt_sample.jpg') }
  let(:uploaded_image) do
    Rack::Test::UploadedFile.new(image_path, 'image/jpeg')
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

    it '手動登録モードでも画面を取得できる' do
      get new_receipt_path, params: { mode: 'manual' }

      expect(response).to have_http_status(:success)
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

      expect(response).to have_http_status(:unprocessable_entity)
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
        expect(response.body).to include('処理に失敗しました')
        expect(response.body).to include('OCR処理に失敗しました')
        expect(response.body).to include('OCR service timeout')
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
        expect(response.body).to include('AI補完処理に失敗しました')
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

    it '不正なパラメータでは更新できない' do
      patch receipt_path(receipt), params: invalid_update_params
      receipt.reload

      aggregate_failures do
        expect([ 200, 422 ]).to include(response.status)
        expect(receipt.store_name).to eq('更新前')
        expect(receipt.total_amount).to eq(1400)
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
