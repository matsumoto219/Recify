require "rails_helper"
require "tmpdir"

RSpec.describe Storage::PreparedImageCleanup do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    Dir.mktmpdir("recify-prepared-cleanup-spec") do |directory|
      @storage_directory = directory
      travel_to(Time.zone.parse("2026-10-13 10:00:00")) { example.run }
    end
  end

  before do
    service = ActiveStorage::Service::DiskService.new(root: @storage_directory)
    service.name = "test"
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)
    allow(ActiveStorage::Blob.services).to receive(:fetch).with("test").and_return(service)
  end

  def create_blob(expires_at: 1.minute.ago, attempt: "a" * 64, owned: true)
    metadata = { "identified" => true, "analyzed" => true }
    if owned
      metadata[Storage::PreparedImages::METADATA_KEY] = { "attempt" => attempt, "expires_at" => expires_at.utc.iso8601 }
    end
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("synthetic body"),
      filename: "synthetic.png",
      content_type: "image/png",
      metadata: metadata,
      identify: false
    ).tap { |blob| blob.update_columns(created_at: 3.days.ago) }
  end

  it "期限を過ぎた今回の未添付画像だけを本体とrowの順に削除する" do
    expired = create_blob
    recent = create_blob(expires_at: 1.hour.from_now)
    unrelated = create_blob(owned: false)
    deleted = []
    allow(expired.service).to receive(:delete).and_wrap_original do |method, key|
      deleted << [ key, ActiveStorage::Blob.exists?(expired.id) ]
      method.call(key)
    end

    expect(described_class.call.deleted).to eq(1)
    expect(deleted).to eq([ [ expired.key, true ] ])
    expect(ActiveStorage::Blob.exists?(expired.id)).to be(false)
    expect(expired.service.exist?(expired.key)).to be(false)
    expect(ActiveStorage::Blob.where(id: [ recent.id, unrelated.id ]).count).to eq(2)
    expect(recent.service.exist?(recent.key)).to be(true)
    expect(unrelated.service.exist?(unrelated.key)).to be(true)
  end

  it "期限経過後でもwriterがfile lockを保持している間はskipする" do
    blob = create_blob

    Storage::UploadLock.call(key: "a" * 64, namespace: "images") do
      expect(described_class.call.deleted).to eq(0)
      expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
      expect(blob.service.exist?(blob.key)).to be(true)
    end

    expect(described_class.call.deleted).to eq(1)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(false)
  end

  it "metadataが残っていても添付済み画像は削除しない" do
    blob = create_blob
    receipt = create(:receipt)
    ActiveStorage::Attachment.create!(record: receipt, name: "image", blob: blob)

    expect(described_class.call.deleted).to eq(0)
    expect(receipt.reload.image.blob).to eq(blob)
    expect(blob.service.exist?(blob.key)).to be(true)
  end

  it "本体削除失敗では追跡rowを残し、例外本文をログへ漏らさない" do
    blob = create_blob
    allow(blob.service).to receive(:delete).with(blob.key).and_raise(IOError, "synthetic-private-payload")
    expect(Rails.logger).to receive(:warn).with("[Storage] prepared_image_cleanup_failed error_class=IOError")

    expect(described_class.call.deleted).to eq(0)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
    expect(blob.reload.metadata).to have_key(Storage::PreparedImages::METADATA_KEY)
    expect(blob.service.exist?(blob.key)).to be(true)
  end

  it "別attemptへの変更後は古い回収処理で削除しない" do
    blob = create_blob(attempt: "b" * 64)

    expect(described_class.discard(blob.id, attempt: "a" * 64)).to be(false)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
    expect(blob.service.exist?(blob.key)).to be(true)
  end

  it "最近の仮画像がlimitを占めても後続の期限切れ画像を回収できる" do
    recent = create_blob(expires_at: 1.hour.from_now)
    expired = create_blob

    expect(described_class.call(limit: 1).deleted).to eq(1)
    expect(ActiveStorage::Blob.exists?(recent.id)).to be(true)
    expect(ActiveStorage::Blob.exists?(expired.id)).to be(false)
  end

  it "整数を文字列へ変換して所有attemptとして受け付けない" do
    blob = create_blob(attempt: ("1" * 64).to_i)

    expect(described_class.call.deleted).to eq(0)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
    expect(blob.service.exist?(blob.key)).to be(true)
  end

  it "既存orphan scannerは今回の仮保存画像を期限に関係なく除外する" do
    recent = create_blob(expires_at: 1.hour.from_now)
    expired = create_blob
    unrelated = create_blob(owned: false)

    result = Storage::OrphanBlobScanner.call

    expect(result[:blob_ids]).to eq([ unrelated.id ])
    expect(result[:blob_ids]).not_to include(recent.id, expired.id)
  end

  it "回収limitの不正値では何も削除しない" do
    blob = create_blob

    [ 0, 1001, "1", nil ].each do |limit|
      expect { described_class.call(limit: limit) }.to raise_error(ArgumentError, "invalid cleanup limit")
    end
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
  end

  it "削除失敗の先頭を越えて巡回し、巡回開始後の画像は次の巡回へ残す" do
    failed = create_blob
    following = create_blob(attempt: "b" * 64)
    allow(failed.service).to receive(:delete).and_call_original
    allow(failed.service).to receive(:delete).with(failed.key).and_raise(IOError)

    first = described_class.call(limit: 1)
    inserted = create_blob(attempt: "c" * 64)
    second = described_class.call(limit: 1, after_id: first.next_after_id, through_id: first.through_id)

    aggregate_failures do
      expect(first.scanned).to eq(1)
      expect(first.deleted).to eq(0)
      expect(first.next_after_id).to eq(failed.id)
      expect(first.through_id).to eq(following.id)
      expect(second.deleted).to eq(1)
      expect(second.next_after_id).to be_nil
      expect(second.through_id).to eq(following.id)
      expect(ActiveStorage::Blob.exists?(following.id)).to be(false)
      expect(ActiveStorage::Blob.exists?(inserted.id)).to be(true)
    end

    allow(failed.service).to receive(:delete).and_call_original
    expect(described_class.call.deleted).to eq(2)
  end

  it "busyな先頭の期限を変えずに後続の画像へ進む" do
    busy = create_blob
    following = create_blob(attempt: "b" * 64)
    original_metadata = busy.metadata.deep_dup

    Storage::UploadLock.call(key: "a" * 64, namespace: "images") do
      first = described_class.call(limit: 1)
      second = described_class.call(limit: 1, after_id: first.next_after_id, through_id: first.through_id)

      expect(second.deleted).to eq(1)
      expect(busy.reload.metadata).to eq(original_metadata)
      expect(ActiveStorage::Blob.exists?(following.id)).to be(false)
    end

    expect(described_class.call.deleted).to eq(1)
  end

  it "不正なcursorは画像を削除せず拒否する" do
    blob = create_blob

    [ { after_id: -1 }, { after_id: "1" }, { through_id: -1 }, { after_id: 2, through_id: 1 } ].each do |cursor|
      expect { described_class.call(**cursor) }.to raise_error(ArgumentError, "invalid cleanup cursor")
    end
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
  end
end
