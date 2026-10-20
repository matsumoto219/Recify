require 'rails_helper'

RSpec.describe 'Receipt upload failure notifications', type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:token) { Receipts::Registrations.issue_token(user: user, kind: 'upload') }
  let(:manual_token) { Receipts::Registrations.issue_token(user: user, kind: 'manual') }
  let(:calculation_context) { Receipts::CalculationContext.build(user: user, receipt: Receipt.new(user: user)).token }
  let(:manual_input) do
    {
      store_name: '保存失敗検証店', purchased_on: '2026-10-13', payment_method: 'cash',
      receipt_items_attributes: {
        '0' => { confirmed_name: '検証商品', price: '100', quantity: '1', line_total: '100', tax_rate: '10' }
      }
    }
  end

  before { sign_in user }

  def uploaded_image
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg')
  end

  def post_upload(value = token)
    post upload_receipts_path, params: { receipt_registration_token: value, receipt: { image: uploaded_image } }
  end

  def post_manual(image: uploaded_image, input: manual_input)
    post receipts_path, params: {
      receipt_registration_token: manual_token,
      receipt_calculation_context: calculation_context,
      receipt: input.merge(image: image)
    }
  end

  def fail_image_storage
    allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(Errno::ENOSPC, 'private storage path')
  end

  it '通知設定OFFでも確定保存失敗は通常一覧へ1件表示し登録や利用回数は増やさない' do
    user.update!(push_notification_enabled: false)
    fail_image_storage
    expect(Receipts::Processing).not_to receive(:start)
    original_counts = [ Receipt.count, ReceiptAnalysisRun.count, UsageCounter.count, ActiveStorage::Blob.count ]

    expect { post_upload }.to change(Notification, :count).by(1)

    expect(response).to have_http_status(:unprocessable_content)
    expect([ Receipt.count, ReceiptAnalysisRun.count, UsageCounter.count, ActiveStorage::Blob.count ]).to eq(original_counts)
    notification = user.notifications.sole
    expect(notification.kind).to eq('receipt_upload_failed')
    expect(notification.attributes.to_json).not_to include(token, 'private storage path', 'receipt_sample.jpg')

    get notifications_path

    document = Nokogiri::HTML(response.body)
    expect(document.at_css("#notifications_list form[action='#{read_notification_path(notification)}']")).to be_present
    expect(document.css('[data-receipt-registration-mode-value="notifications"]')).to be_empty
  end

  it '通知を開くと既存の読了処理で既読にしてOCRの新しい入力フォームへ移る' do
    fail_image_storage
    post_upload
    notification = user.notifications.sole

    patch read_notification_path(notification)

    expect(response).to redirect_to(new_upload_receipts_path)
    expect(notification.reload).to be_read
    follow_redirect!
    current_token = Nokogiri::HTML(response.body).at_css('input[name="receipt_registration_token"]')['value']
    expect(current_token).not_to eq(token)
    expect(ReceiptRegistrationOperation.count).to eq(1)
  end

  it '削除した通知を同じフォームの失敗再送で作り直さない' do
    fail_image_storage
    post_upload
    delete notification_path(user.notifications.sole)

    expect { post_upload }.not_to change(Notification, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.receipt_registration_operations.sole.notification_reported).to be(true)
  end

  it '複数画像の最後の保存失敗でも通常通知は1件で受付は0件にする' do
    calls = 0
    allow(ActiveStorage::Blob.service).to receive(:upload).and_wrap_original do |method, *arguments, **options|
      calls += 1
      raise Errno::ENOSPC if calls == 2

      method.call(*arguments, **options)
    end

    expect do
      post upload_receipts_path, params: { receipt_registration_token: token, receipt: { images: [ uploaded_image, uploaded_image ] } }
    end.to change(Notification, :count).by(1)

    expect(user.receipts.reload).to be_empty
    expect(UsageCounter.where(user: user)).to be_empty
    expect(user.notifications.sole.action_path).to eq(new_upload_receipts_path)
  end

  it '画像付き手動登録の保存失敗は手動フォームへ戻す' do
    fail_image_storage

    expect { post_manual }.to change(Notification, :count).by(1)

    expect(response).to have_http_status(:unprocessable_content)
    patch read_notification_path(user.notifications.sole)
    expect(response).to redirect_to(new_receipt_path)
    expect(user.receipts.reload).to be_empty
    expect(UsageCounter.where(user: user)).to be_empty
  end

  it '受付記録の期限後cleanupを経ても元フォームへの読了遷移を維持する' do
    fail_image_storage
    post_upload
    notification = user.notifications.sole

    travel 24.hours do
      expect(Receipts::Registrations.cleanup_expired.deleted).to eq(1)
      patch read_notification_path(notification)

      expect(response).to redirect_to(new_upload_receipts_path)
      expect(notification.reload).to be_read
      expect(notification.notifiable).to be_nil
    end
  end

  it '入力不備や画像なし手動登録では画像保存失敗の通知を出さない' do
    fail_image_storage

    expect { post_manual(image: nil, input: manual_input.merge(store_name: '')) }.not_to change(Notification, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(user.receipts.reload).to be_empty
  end

  it '入力画像がない場合は通常エラーだけにする' do
    expect(Receipts::Processing).not_to receive(:start)
    original_counts = [ Receipt.count, ReceiptAnalysisRun.count, UsageCounter.count, ActiveStorage::Blob.count ]

    expect do
      post upload_receipts_path, params: { receipt_registration_token: token, receipt: { image: nil } }
    end.not_to change(Notification, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect([ Receipt.count, ReceiptAnalysisRun.count, UsageCounter.count, ActiveStorage::Blob.count ]).to eq(original_counts)
    expect(user.receipts.reload).to be_empty
  end

  it '容量不足は通常の拒否だけにする' do
    allow(Storage).to receive(:global_quota_can_add?).and_return(false)

    expect { post_upload }.not_to change(Notification, :count)

    expect(user.receipts.reload).to be_empty
    expect(UsageCounter.where(user: user)).to be_empty
  end

  it '解析enqueue失敗は既存解析失敗通知だけを使い画像保存失敗通知は出さない' do
    allow(ReceiptOcrJob).to receive(:perform_later).and_raise(StandardError, 'synthetic queue failure')

    expect { post_upload }.not_to change { Notification.where(kind: 'receipt_upload_failed').count }

    receipt = user.receipts.sole
    expect(receipt).to be_failed
    expect(receipt.image).to be_attached
    expect(UsageCounter.find_by!(user: user, key: 'receipt_uploads_per_day').used_count).to eq(1)
  end

  it '未認証や他ユーザーのtokenでは通知を作らない' do
    other_token = Receipts::Registrations.issue_token(user: create(:user), kind: 'upload')
    expect { post_upload(other_token) }.not_to change(Notification, :count)
    expect(response).to have_http_status(:unprocessable_content)
    issued_token = token
    sign_out user

    expect { post_upload(issued_token) }.not_to change(Notification, :count)
    expect(response).to redirect_to(new_user_session_path)
  end

  it '他ユーザーは失敗通知を既読化できない' do
    fail_image_storage
    post_upload
    notification = user.notifications.sole
    sign_in create(:user)

    patch read_notification_path(notification)
    expect(response).to have_http_status(:not_found)
    expect(notification.reload).to be_unread
  end

  it '他ユーザーは失敗通知を削除できない' do
    fail_image_storage
    post_upload
    notification = user.notifications.sole
    sign_in create(:user)

    expect { delete notification_path(notification) }.not_to change(Notification, :count)

    expect(response).to have_http_status(:not_found)
  end

  it 'CSRF不正な新規送信は保存処理へ進まず通知もしない' do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    expect(Receipts::Uploads).not_to receive(:single)

    expect { post_upload }.not_to change(Notification, :count)

    expect(response).to have_http_status(:unprocessable_content)
  ensure
    ActionController::Base.allow_forgery_protection = original unless original.nil?
  end
end
