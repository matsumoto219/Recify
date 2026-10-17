require 'rails_helper'

RSpec.describe Storage::PreparedImages do
  let(:user) { create(:user) }
  let(:image) { Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg') }
  let(:receipt) { user.receipts.new(image: image, status: 'processing') }

  def prepare(records = [ receipt ], &block)
    described_class.call(records: records, attachment_name: :image, user: user, &block)
  end

  it '本体が保存された後だけ受付transactionを実行し、画像を再uploadしない' do
    expect(ActiveStorage::Blob.service).to receive(:upload).once.and_call_original

    result = prepare do
      expect(receipt.image.blob.service.exist?(receipt.image.blob.key)).to be(true)
      expect(receipt.image.blob.metadata).to include('width', 'height')
      receipt.save!
    end

    expect(result).to be(true)
    expect(receipt.reload.image.blob.metadata).not_to have_key('upload_preparation')
    expect(receipt.image.download).to eq(File.binread(image.path))
  end

  it '最後の本体保存失敗では受付せず、追跡可能な画像を後始末する' do
    second = user.receipts.new(image: image, status: 'processing')
    calls = 0
    allow(ActiveStorage::Blob.service).to receive(:upload).and_wrap_original do |method, *args, **keywords|
      calls += 1
      raise Errno::ENOSPC if calls == 2

      method.call(*args, **keywords)
    end

    expect do
      expect(prepare([ receipt, second ]) { raise 'must not accept' }).to be(false)
    end.not_to change(Receipt, :count)

    expect(ActiveStorage::Blob.count).to eq(0)
    expect(receipt.errors).to be_of_kind(:image, :upload_failed)
  end

  it '受付blockがfalseなら全recordと添付をrollbackする' do
    result = prepare do
      receipt.save!
      false
    end

    expect(result).to be(false)
    expect(user.receipts.reload).to be_empty
    expect(ActiveStorage::Attachment.count).to eq(0)
    expect(ActiveStorage::Blob.count).to eq(0)
  end

  it '差し替え保存失敗では旧添付と本体を維持する' do
    old = create(:receipt, :with_image, user: user)
    old_blob = old.image.blob
    old.image = image
    allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(Errno::ENOSPC)

    expect(prepare([ old ]) { old.save! }).to be(false)
    expect(old.image.blob).to eq(old_blob)
    expect(old.reload.image.blob).to eq(old_blob)
    expect(old_blob.service.exist?(old_blob.key)).to be(true)
  end

  it '準備中に差し替え対象が変わった場合は別writerを上書きしない' do
    old = create(:receipt, :with_image, user: user)
    old.image = image
    allow(ActiveStorage::Blob.service).to receive(:upload).and_wrap_original do |method, *args, **keywords|
      method.call(*args, **keywords)
      ActiveStorage::Attachment.where(record: old, name: 'image').delete_all
    end

    expect do
      prepare([ old ]) { old.save! }
    end.to raise_error(ActiveRecord::StaleObjectError)

    expect(old.reload.image).not_to be_attached
  end

  it '既存のvalidationエラーでは本体も仮Blobも保存しない' do
    receipt.image.blob.content_type = 'application/pdf'
    expect(ActiveStorage::Blob.service).not_to receive(:upload)

    expect(prepare { receipt.save! }).to be(false)
    expect(ActiveStorage::Blob.count).to eq(0)
  end

  it '画像保存以外のI/O例外は握り潰さず、受付をrollbackする' do
    expect do
      prepare do
        receipt.save!
        raise IOError, 'synthetic transaction failure'
      end
    end.to raise_error(IOError, 'synthetic transaction failure')

    expect(user.receipts.reload).to be_empty
    expect(ActiveStorage::Blob.count).to eq(0)
  end

  it '画像lockが使用中なら保存も受付もせず再試行可能なエラーにする' do
    allow(Storage::UploadLock).to receive(:call).and_return(nil)
    expect(ActiveStorage::Blob.service).not_to receive(:upload)

    expect(prepare { raise 'must not accept' }).to be(false)
    expect(receipt.errors).to be_of_kind(:image, :upload_in_progress)
    expect(receipt.errors).not_to be_of_kind(:image, :upload_failed)
    expect(ActiveStorage::Blob.count).to eq(0)
  end

  it '失敗後の本体削除に失敗しても24時間待たずに限定cleanupで再試行できる' do
    allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(Errno::ENOSPC)
    allow(ActiveStorage::Blob.service).to receive(:delete).and_raise(IOError, 'synthetic deletion failure')

    expect(prepare { raise 'must not accept' }).to be(false)
    expect(ActiveStorage::Blob.count).to eq(1)

    allow(ActiveStorage::Blob.service).to receive(:delete).and_call_original
    expect(Storage::PreparedImageCleanup.call.deleted).to eq(1)
    expect(ActiveStorage::Blob.count).to eq(0)
    expect(user.receipts.reload).to be_empty
  end

  context '容量の予約と確定' do
    def set_user_limit(bytes)
      allow(UserLimits).to receive(:effective_limit).and_call_original
      allow(UserLimits).to receive(:effective_limit).with(user: user, key: 'storage_bytes').and_return(bytes)
    end

    def set_global_limit(bytes)
      allow(SystemSettings).to receive(:limit_for).and_call_original
      allow(SystemSettings).to receive(:limit_for).with('storage.global_hard_stop_bytes').and_return(bytes)
    end

    it '予約済みの自分の画像をfinalで二重計上しない' do
      set_user_limit(image.size)
      set_global_limit(image.size)

      expect(prepare { receipt.save! }).to be(true)
      expect(Storage.usage_calculator(user).used_bytes).to eq(image.size)
    end

    it '別の未確定画像もユーザーの予約量に含めて拒否する' do
      ActiveStorage::Blob.create!(
        filename: 'pending.jpg',
        content_type: 'image/jpeg',
        byte_size: image.size,
        checksum: 'synthetic',
        metadata: { 'upload_preparation' => { 'attempt' => 'a' * 64, 'user_id' => user.id, 'expires_at' => 1.hour.from_now.utc.iso8601 } }
      )
      set_user_limit(image.size)
      expect(ActiveStorage::Blob.service).not_to receive(:upload)

      expect { prepare { raise 'must not accept' } }.to raise_error(Storage::QuotaExceeded) do |error|
        expect(error.scope).to eq(:user)
      end
    end

    it '差し替え後のuser容量を使い、globalには旧画像と新画像を両方計上する' do
      old = create(:receipt, :with_image, user: user)
      old_size = old.image.blob.byte_size
      old.image = image
      set_user_limit(image.size)
      set_global_limit(old_size + image.size)

      expect(prepare([ old ]) { old.save! }).to be(true)
      expect(old.reload.image.download).to eq(File.binread(image.path))
    end

    it '旧画像を除外しないとglobal上限へ収まらない差し替えは旧画像を保持して拒否する' do
      old = create(:receipt, :with_image, user: user)
      old_blob = old.image.blob
      old.image = image
      set_global_limit(old_blob.byte_size + image.size - 1)
      expect(ActiveStorage::Blob.service).not_to receive(:upload)

      expect { prepare([ old ]) { old.save! } }.to raise_error(Storage::QuotaExceeded) do |error|
        expect(error.scope).to eq(:global)
      end
      expect(old.reload.image.blob).to eq(old_blob)
    end

    it '本体保存中にuser上限が下がればfinalで再確認して受付を拒否する' do
      set_user_limit(image.size)
      allow(ActiveStorage::Blob.service).to receive(:upload).and_wrap_original do |method, *args, **keywords|
        method.call(*args, **keywords)
        set_user_limit(image.size - 1)
      end

      expect { prepare { raise 'must not accept' } }.to raise_error(Storage::QuotaExceeded) do |error|
        expect(error.scope).to eq(:user)
      end
      expect(ActiveStorage::Blob.count).to eq(0)
      expect(user.receipts.reload).to be_empty
    end
  end
end
