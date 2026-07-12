require 'rails_helper'

RSpec.describe 'Active Storage purge enqueue fallback' do
  def create_blob(content = 'local purge fallback fixture')
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(content),
      filename: 'purge-fallback.txt',
      content_type: 'text/plain'
    )
  end

  it 'purge jobがfalseを返した場合は同期purgeする' do
    blob = create_blob
    key = blob.key
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).with(blob).and_return(false)

    blob.purge_later

    aggregate_failures do
      expect(ActiveStorage::Blob).not_to exist(blob.id)
      expect(blob.service).not_to exist(key)
    end
  end

  it 'Solid Queue enqueue errorの場合は同期purgeする' do
    blob = create_blob
    key = blob.key
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).with(blob)
      .and_raise(SolidQueue::Job::EnqueueError, 'local enqueue failure')

    expect { blob.purge_later }.not_to raise_error

    aggregate_failures do
      expect(ActiveStorage::Blob).not_to exist(blob.id)
      expect(blob.service).not_to exist(key)
    end
  end

  it '通常enqueue成功時は同期purgeしない' do
    blob = create_blob
    queued_job = instance_double(ActiveStorage::PurgeJob)
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).with(blob).and_return(queued_job)
    expect(blob).not_to receive(:purge)

    expect(blob.purge_later).to be(queued_job)
    expect(ActiveStorage::Blob).to exist(blob.id)
  end

  it 'Solid Queue以外の例外を握り潰さない' do
    blob = create_blob
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).with(blob)
      .and_raise(RuntimeError, 'unexpected adapter failure')

    expect { blob.purge_later }.to raise_error(RuntimeError, 'unexpected adapter failure')
    expect(ActiveStorage::Blob).to exist(blob.id)
  end

  it '同期fallback自体の失敗は機微情報なしで記録して親削除を妨げない' do
    blob = create_blob
    messages = []
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).with(blob).and_return(false)
    allow(blob).to receive(:purge).and_raise(
      RuntimeError,
      "key=#{blob.key} signed_url=/rails/active_storage/blobs/redirect/local-secret/file"
    )
    allow(Rails.logger).to receive(:error) { |message| messages << message.to_s }

    expect { blob.purge_later }.not_to raise_error

    log = messages.join("\n")

    aggregate_failures do
      expect(log).to include('[ActiveStoragePurgeFallback]', "blob_id=#{blob.id}", 'class=RuntimeError')
      expect(log).not_to include(blob.key, 'local-secret', 'purge-fallback.txt')
    end
  end
end
