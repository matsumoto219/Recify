require "rails_helper"

RSpec.describe "Storage public payload boundary" do
  SYSTEM_USAGE_KEYS = %i[
    total_blob_count
    attached_blob_count
    orphan_blob_count
    total_blob_bytes
    attached_blob_bytes
    orphan_blob_bytes
    user_count
    quota_total_bytes
    quota_used_bytes
    global_quota
  ].freeze
  GLOBAL_QUOTA_KEYS = %i[
    used_bytes
    hard_stop_bytes
    warning_percentage
    critical_percentage
    warning_bytes
    critical_bytes
    remaining_bytes
    usage_percentage
    state
  ].freeze
  ORPHAN_SCAN_KEYS = %i[count bytes blob_ids sample created_before older_than_seconds].freeze
  ORPHAN_SAMPLE_KEYS = %i[id content_type byte_size created_at].freeze
  PURGE_RESULT_KEYS = %i[
    dry_run
    cutoff
    retention_days
    limit
    candidate_count
    purged_count
    skipped_count
    failed_count
    sample_receipt_ids
    sample_receipt_public_ids
    records
    errors
  ].freeze
  PURGE_RECORD_KEYS = %i[receipt_id receipt_public_id status image_purge_eligible_at].freeze
  FORBIDDEN_KEY_PATTERN = /(?:key|filename|checksum|metadata|signed|url|token|secret|password|authorization)/i

  def create_blob(filename: "private-user@example.test.jpg")
    ActiveStorage::Blob.create!(
      key: "private-storage-key-#{SecureRandom.hex(8)}",
      filename: filename,
      content_type: "image/jpeg",
      metadata: { private: true },
      service_name: ActiveStorage::Blob.service.name,
      byte_size: 1.kilobyte,
      checksum: SecureRandom.base64(16),
      created_at: 3.days.ago
    )
  end

  def recursive_keys(value)
    case value
    when Hash
      value.flat_map { |key, child| [ key.to_s ] + recursive_keys(child) }
    when Array
      value.flat_map { |child| recursive_keys(child) }
    else
      []
    end
  end

  it "system usage snapshotをexact aggregate schemaに限定する" do
    snapshot = Storage.system_usage_snapshot

    aggregate_failures do
      expect(snapshot.keys).to contain_exactly(*SYSTEM_USAGE_KEYS)
      expect(snapshot.fetch(:global_quota).keys).to contain_exactly(*GLOBAL_QUOTA_KEYS)
      expect(recursive_keys(snapshot).grep(FORBIDDEN_KEY_PATTERN)).to be_empty
    end
  end

  it "orphan blob scanからstorage secretと個人filenameを除外する" do
    blob = create_blob
    result = Storage.orphan_blob_scan
    sample = result.fetch(:sample).sole

    aggregate_failures do
      expect(result.keys).to contain_exactly(*ORPHAN_SCAN_KEYS)
      expect(sample.keys).to contain_exactly(*ORPHAN_SAMPLE_KEYS)
      expect(recursive_keys(result).grep(FORBIDDEN_KEY_PATTERN)).to be_empty
      expect(result.to_json).not_to include(blob.key, blob.filename.to_s, blob.checksum)
    end
  end

  it "receipt image purge payloadをpublic receipt識別子とsafe error schemaに限定する" do
    receipt = create(
      :receipt,
      :completed,
      :with_image,
      keep_image: false,
      image_purge_eligible_at: 3.days.ago
    )
    result = Storage.purge_receipt_images(dry_run: true)
    record = result.fetch(:records).sole

    aggregate_failures do
      expect(result.keys).to contain_exactly(*PURGE_RESULT_KEYS)
      expect(record.keys).to contain_exactly(*PURGE_RECORD_KEYS)
      expect(record).to include(receipt_id: receipt.id, receipt_public_id: receipt.public_id)
      expect(recursive_keys(result).grep(FORBIDDEN_KEY_PATTERN)).to be_empty
      expect(result.to_json).not_to include(receipt.image.blob.key, receipt.image.blob.filename.to_s)
    end
  end
end
