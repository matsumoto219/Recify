require "rails_helper"
require "tmpdir"

RSpec.describe "Receipt registration operations", type: :request do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:manual_token) { Receipts::Registrations.issue_token(user:, kind: "manual") }
  let(:upload_token) { Receipts::Registrations.issue_token(user:, kind: "upload") }
  let(:calculation_context) { Receipts::CalculationContext.build(user:, receipt: Receipt.new(user:)) }
  let(:manual_input) do
    {
      store_name: "登録確認用店舗", purchased_on: "2026-10-13", payment_method: "cash",
      receipt_items_attributes: {
        "0" => { confirmed_name: "登録確認用商品", price: "100", quantity: "1", line_total: "100", tax_rate: "10" }
      }
    }
  end

  before { sign_in user }

  def post_manual(token: manual_token, context: calculation_context, input: manual_input)
    post receipts_path, params: {
      receipt_registration_token: token,
      receipt_calculation_context: context.token,
      receipt: input
    }
  end

  def uploaded_image
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/receipt_sample.jpg"), "image/jpeg")
  end

  it "新規フォームは受付を作らずhidden tokenだけを発行し、復帰UIを追加しない" do
    expect { get new_receipt_path }.not_to change { [ ReceiptRegistrationOperation.count, Receipt.count, Notification.count ] }

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('input[name="receipt_registration_token"]')["value"]).to be_present
    expect(document.css('[data-receipt-registration-mode-value], [data-receipt-registration-status-url-value]')).to be_empty
    expect(document.css('[data-receipt-registration-pending-limit-value]')).to be_empty
  end

  it "受付IDなしの手動登録を金額計算前に拒否する" do
    expect(ReceiptAmountService).not_to receive(:call)
    expect(Receipts::Editing).not_to receive(:create_manual)

    expect { post_manual(token: nil) }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t("receipt_registration.submission.invalid"))
  end

  it "受付IDなしの画像登録を保存前に拒否し、元フォームで案内する" do
    expect(Receipts::Uploads).not_to receive(:single)

    post upload_receipts_path, params: { receipt: { image: uploaded_image } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t("receipt_registration.submission.invalid"))
    expect(Nokogiri::HTML(response.body).at_css('form[action="/receipts/upload"]')).to be_present
  end

  it "同じ手動登録の再送はReceiptと利用回数を増やさない" do
    post_manual
    expect(response).to redirect_to(receipts_path)
    first_ids = user.receipts.pluck(:id)
    first_usage = UsageCounter.where(user:).sum(:used_count)
    expect(first_ids.size).to eq(1)

    expect(ReceiptAmountService).not_to receive(:call)
    expect(Receipts::Editing).not_to receive(:create_manual)
    post_manual

    expect(response).to have_http_status(:see_other)
    expect(user.receipts.pluck(:id)).to eq(first_ids)
    expect(UsageCounter.where(user:).sum(:used_count)).to eq(first_usage)
    expect(response.headers["X-Receipt-Registration-State"]).to eq("accepted")
  end

  it "再発行された計算contextのnonceが違っても同じdefaultsなら再送として扱う" do
    post_manual
    new_context = Receipts::CalculationContext.build(user:, receipt: Receipt.new(user:))
    expect(new_context.token).not_to eq(calculation_context.token)

    expect { post_manual(context: new_context) }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:see_other)
  end

  it "同じ受付IDで手動sourceを変更した場合は上書きも新規登録もしない" do
    post_manual

    expect { post_manual(input: manual_input.merge(memo: "異なる入力")) }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.body).to include(I18n.t("receipt_registration.submission.conflict"))
  end

  it "署名済み計算defaultsが変わった場合は同じ入力へ潰さない" do
    post_manual
    user.tax_rounding_mode = "ceil"
    changed_context = Receipts::CalculationContext.build(user:, receipt: Receipt.new(user:))

    expect { post_manual(context: changed_context) }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:conflict)
  end

  it "既受付画像の再送をOCR停止や容量不足の事前確認より先に解決する" do
    post upload_receipts_path, params: { receipt_registration_token: upload_token, receipt: { image: uploaded_image } }
    expect(response).to redirect_to(receipts_path)
    receipt_ids = user.receipts.pluck(:id)
    run_count = ReceiptAnalysisRun.count
    usage_count = UsageCounter.where(user:).sum(:used_count)
    blob_count = ActiveStorage::Blob.count
    job_count = enqueued_jobs.size

    expect(ExternalServices).not_to receive(:down?)
    expect(Storage).not_to receive(:global_quota_can_add?)
    expect(Receipts::Uploads).not_to receive(:single)
    post upload_receipts_path, params: { receipt_registration_token: upload_token, receipt: { image: uploaded_image } }

    expect(response).to have_http_status(:see_other)
    expect(user.receipts.pluck(:id)).to eq(receipt_ids)
    expect(ReceiptAnalysisRun.count).to eq(run_count)
    expect(UsageCounter.where(user:).sum(:used_count)).to eq(usage_count)
    expect(ActiveStorage::Blob.count).to eq(blob_count)
    expect(enqueued_jobs.size).to eq(job_count)
  end

  it "受付IDの期限切れでは自動で新しい登録を始めない" do
    token = upload_token
    travel 24.hours do
      expect(Receipts::Uploads).not_to receive(:single)
      post upload_receipts_path, params: { receipt_registration_token: token, receipt: { image: uploaded_image } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t("receipt_registration.submission.expired"))
    end
  end

  it "他ユーザーの受付IDで登録しない" do
    token = Receipts::Registrations.issue_token(user: create(:user), kind: "manual")

    expect { post_manual(token:) }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "受付処理中はフォームを再送せず一覧確認を案内する" do
    allow(Receipts::Registrations).to receive(:with_operation).and_return(
      Receipts::Registrations::Result.new(state: "processing", kind: "manual")
    )
    expect(ReceiptAmountService).not_to receive(:call)

    expect { post_manual }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.body).to include(I18n.t("receipt_registration.submission.processing"))
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('input[name="receipt_registration_token"]')["value"]).to eq(manual_token)
    expect(document.at_css('input[name="receipt[store_name]"]')["value"]).to eq(manual_input[:store_name])
  end

  it "確定したvalidation失敗は元の受付をfailedにして再入力用tokenを表示する" do
    post_manual(input: manual_input.merge(store_name: ""))

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.receipt_registration_operations.sole.state).to eq("failed")
    token = Nokogiri::HTML(response.body).at_css('input[name="receipt_registration_token"]')&.[]("value")
    expect(token).to be_present
    expect(token).not_to eq(manual_token)
    expect(user.receipt_registration_operations.count).to eq(1)
  end

  it "削除済みReceiptの操作を再送しても再作成しない" do
    post_manual
    user.receipts.sole.destroy!

    expect { post_manual }.not_to change { [ Receipt.count, UsageCounter.where(user:).sum(:used_count) ] }

    expect(response).to have_http_status(:see_other)
    expect(response.headers["X-Receipt-Registration-State"]).to eq("accepted")
  end

  it "URL queryの受付tokenを受け付けない" do
    expect {
      post upload_receipts_path(receipt_registration_token: upload_token), params: { receipt: { image: uploaded_image } }
    }.not_to change(Receipt, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.headers["X-Receipt-Registration-State"]).to eq("invalid")
  end

  it "未認証の同一フォーム再送を拒否する" do
    token = manual_token
    sign_out user

    expect { post_manual(token:) }.not_to change(ReceiptRegistrationOperation, :count)

    expect(response).to redirect_to(new_user_session_path)
    expect(response.body).not_to include(token)
  end

  it "新規登録も既存のCSRF保護を通過しなければ受付しない" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    expect(Receipts::Registrations).not_to receive(:with_operation)

    post_manual

    expect(response).to have_http_status(:unprocessable_content)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  it "受付tokenをrequest logのparameter filterで秘匿する" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      "receipt_registration_token" => "private-registration-token"
    )

    expect(filtered).to eq("receipt_registration_token" => "[FILTERED]")
  end

  context "実transactionでのHTTP受付" do
    self.use_transactional_tests = false

    around do |example|
      Dir.mktmpdir("recify-registration-request") do |directory|
        @storage_directory = directory
        example.run
      end
    end

    before do
      @service = ActiveStorage::Service::DiskService.new(root: @storage_directory)
      @service.name = "test"
      allow(ActiveStorage::Blob).to receive(:service).and_return(@service)
      allow(ActiveStorage::Blob.services).to receive(:fetch).with("test").and_return(@service)
      allow(ExternalServices).to receive(:down?).with(:ocr).and_return(false)
      allow(ReceiptOcrJob).to receive(:perform_later).and_return(instance_double(ReceiptOcrJob))
      @blob_ids = []
      @original_jobs = enqueued_jobs.dup
    end

    after do
      User.where(id: user.id).destroy_all
      ActiveStorage::Blob.where(id: @blob_ids).find_each(&:purge)
      enqueued_jobs.replace(@original_jobs)
    end

    %i[single batch manual].each do |flow|
      it "#{flow}の画像本体をDB transaction外で保存し、登録と受付を同時に確定する" do
        uploads = []
        allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
          blob = ActiveStorage::Blob.find_by!(key:)
          @blob_ids << blob.id
          uploads << key
          aggregate_failures do
            expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
            expect(Receipt.where(user:)).to be_empty
            expect(UsageCounter.where(user:)).to be_empty
            expect(ReceiptRegistrationOperation.where(user:).pluck(:state)).to eq([ "processing" ])
            expect(blob.attachments).to be_empty
          end
          method.call(key, io, **options)
        end

        if flow == :manual
          post_manual(input: manual_input.merge(image: uploaded_image))
        else
          image_input = flow == :batch ? { images: [ uploaded_image, uploaded_image ] } : { image: uploaded_image }
          post upload_receipts_path, params: { receipt_registration_token: upload_token, receipt: image_input }
        end

        expect(response).to redirect_to(receipts_path)
        expected_count = flow == :batch ? 2 : 1
        expect(uploads.size).to eq(expected_count)
        expect(user.receipts.count).to eq(expected_count)
        expect(UsageCounter.where(user:).sum(:used_count)).to eq(expected_count)
        accepted = user.receipt_registration_operations.sole
        expect(accepted.state).to eq("accepted")
        expect(accepted.receipt_ids).to match_array(user.receipts.pluck(:id))
      end
    end

    it "画像数上限20件を1受付として保存し、上限引下げ後の同一再送でも利用回数を増やさない" do
      setting = create(:system_setting, key: "limits.batch_upload_max_files", value: SystemSettings.stored_value(20))
      allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
        @blob_ids << ActiveStorage::Blob.find_by!(key:).id
        method.call(key, io, **options)
      end

      post upload_receipts_path, params: {
        receipt_registration_token: upload_token, receipt: { images: Array.new(20) { uploaded_image } }
      }

      expect(response).to redirect_to(receipts_path)
      expect(user.receipts.count).to eq(20)
      expect(user.receipt_registration_operations.count).to eq(1)
      expect(user.receipt_registration_operations.sole.receipt_ids.size).to eq(20)
      expect(UsageCounter.find_by!(user:, key: "batch_files_per_day").used_count).to eq(20)
      setting.update!(value: SystemSettings.stored_value(1))

      expect(Receipts::Uploads).not_to receive(:batch)
      expect {
        post upload_receipts_path, params: {
          receipt_registration_token: upload_token, receipt: { images: Array.new(20) { uploaded_image } }
        }
      }.not_to change { [ Receipt.count, ReceiptAnalysisRun.count, ActiveStorage::Blob.count, UsageCounter.where(user:).sum(:used_count) ] }

      expect(response).to have_http_status(:see_other)
      expect(response.headers["X-Receipt-Registration-State"]).to eq("accepted")
    ensure
      setting&.destroy!
    end

    it "複数画像の後半で本体保存が失敗した場合は登録・利用回数・受付を確定しない" do
      uploads = 0
      allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
        @blob_ids << ActiveStorage::Blob.find_by!(key:).id
        uploads += 1
        raise IOError, "synthetic storage failure" if uploads == 2

        method.call(key, io, **options)
      end

      post upload_receipts_path, params: {
        receipt_registration_token: upload_token,
        receipt: { images: [ uploaded_image, uploaded_image ] }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Receipt.where(user:)).to be_empty
      expect(UsageCounter.where(user:)).to be_empty
      expect(ReceiptAnalysisRun.where(requested_by_user: user)).to be_empty
      expect(user.receipt_registration_operations.sole.state).to eq("failed")
      expect(ActiveStorage::Blob.where(id: @blob_ids)).to be_empty
    end
  end
end
