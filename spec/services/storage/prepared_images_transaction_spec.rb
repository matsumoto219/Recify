require "rails_helper"
require "tmpdir"

RSpec.describe "Prepared image commit boundaries" do
  self.use_transactional_tests = false

  around do |example|
    Dir.mktmpdir("recify-prepared-transaction-spec") do |directory|
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
    @original_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
    @blob_ids = []
    @user = create(:user)
  end

  after do
    if @user
      receipt_ids = Receipt.where(user_id: @user.id).pluck(:id)
      attached_ids = ActiveStorage::Attachment.where(record_type: "Receipt", record_id: receipt_ids).pluck(:blob_id)
      staged_ids = Storage::PreparedImageCleanup.scope.where(
        "metadata::jsonb -> ? ->> 'user_id' = ?", Storage::PreparedImages::METADATA_KEY, @user.id.to_s
      ).pluck(:id)
      User.where(id: @user.id).destroy_all
      ActiveStorage::Blob.where(id: @blob_ids | attached_ids | staged_ids).find_each(&:purge)
    end
    ActiveJob::Base.queue_adapter.enqueued_jobs.replace(@original_jobs) if @original_jobs
  end

  def uploaded_image
    Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/receipt_sample.jpg"), "image/jpeg")
  end

  def create_receipt(flow)
    case flow
    when :single
      Receipts::Uploads.single(user: @user, image: uploaded_image).saved?
    when :batch
      Receipts::Uploads.batch(user: @user, files: [ uploaded_image, uploaded_image ]).success?
    when :manual
      Receipts::Editing.create_manual(
        receipt: @user.receipts.new,
        user: @user,
        items_missing: false,
        attributes: {
          "store_name" => "Synthetic store",
          "total_amount" => 1000,
          "payment_method" => "cash",
          "image" => uploaded_image,
          "receipt_items_attributes" => {
            "0" => { "confirmed_name" => "Synthetic item", "price" => 1000, "quantity" => 1, "line_total" => 1000 }
          }
        }
      ).saved?
    end
  end

  {
    single: [ "receipt_uploads_per_day", 1 ],
    batch: [ "batch_files_per_day", 2 ],
    manual: [ "manual_receipts_per_day", 1 ]
  }.each do |flow, (counter_key, image_count)|
    context flow.to_s do
      it "commit済みBlobの本体保存はDB transaction外で行い、完了後だけ登録と利用回数を確定する" do
        body_uploads = []
        allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
          blob = ActiveStorage::Blob.find_by!(key: key)
          @blob_ids << blob.id
          body_uploads << key
          aggregate_failures do
            expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
            expect(Receipt.where(user_id: @user.id)).to be_empty
            expect(UsageCounter.where(user_id: @user.id)).to be_empty
            expect(blob.attachments).to be_empty
          end
          method.call(key, io, **options)
        end

        expect(create_receipt(flow)).to be(true)

        receipts = Receipt.where(user_id: @user.id)
        aggregate_failures do
          expect(body_uploads.size).to eq(image_count)
          expect(receipts.count).to eq(image_count)
          expect(UsageCounter.find_by!(user_id: @user.id, key: counter_key).used_count).to eq(image_count)
          expect(receipts).to all(satisfy { |receipt| receipt.image.attached? && @service.exist?(receipt.image.blob.key) })
          expect(Storage::PreparedImageCleanup.scope.where(id: @blob_ids)).to be_empty
          expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
        end
      end

      it "最後の画像I/O失敗はReceiptと利用回数を残さず、既存レシートの画像へ影響しない" do
        existing = create(:receipt, :with_image, user: @user)
        old_blob = existing.image.blob
        old_bytes = old_blob.download
        body_uploads = 0
        allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
          @blob_ids << ActiveStorage::Blob.find_by!(key: key).id
          expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
          body_uploads += 1
          method.call(key, io, **options)
          raise Errno::ENOSPC if body_uploads == image_count
        end

        expect(create_receipt(flow)).to be(false)

        aggregate_failures do
          expect(Receipt.where(user_id: @user.id).pluck(:id)).to eq([ existing.id ])
          expect(UsageCounter.where(user_id: @user.id)).to be_empty
          expect(ActiveStorage::Blob.where(id: @blob_ids)).to be_empty
          expect(existing.reload.image.blob).to eq(old_blob)
          expect(old_blob.download).to eq(old_bytes)
          expect(ReceiptOcrJob).not_to have_received(:perform_later)
          expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
        end
      end
    end
  end

  it "差し替えのcommit失敗では旧添付を復元し、準備済み本体だけを破棄する" do
    receipt = create(:receipt, :with_image, user: @user)
    old_blob = receipt.image.blob
    old_bytes = old_blob.download
    receipt.image = uploaded_image
    new_key = nil
    allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
      new_key = key
      @blob_ids << ActiveStorage::Blob.find_by!(key: key).id
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      method.call(key, io, **options)
    end

    expect do
      Storage.with_prepared_images(records: [ receipt ], attachment_name: :image, user: @user) do
        receipt.save!
        raise ActiveRecord::RecordNotSaved, "synthetic transaction failure"
      end
    end.to raise_error(ActiveRecord::RecordNotSaved, "synthetic transaction failure")

    aggregate_failures do
      expect(receipt.reload.image.blob).to eq(old_blob)
      expect(old_blob.download).to eq(old_bytes)
      expect(@service.exist?(new_key)).to be(false)
      expect(ActiveStorage::Blob.where(id: @blob_ids)).to be_empty
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
    end
  end
end
