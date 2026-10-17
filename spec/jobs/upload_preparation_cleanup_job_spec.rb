require 'rails_helper'

RSpec.describe UploadPreparationCleanupJob, type: :job do
  def image_result(deleted: 0, next_after_id: nil, through_id: 0)
    Struct.new(:deleted, :next_after_id, :through_id).new(deleted, next_after_id, through_id)
  end

  def registration_result(scanned: 0, deleted: 0, pending: 0, busy: 0, failed: 0, next_after_id: nil, through_id: 0)
    Struct.new(:scanned, :deleted, :pending, :busy, :failed, :next_after_id, :through_id)
      .new(scanned, deleted, pending, busy, failed, next_after_id, through_id)
  end

  it '未確定画像のcleanup後に期限後の受付記録だけをcleanupする' do
    result = registration_result(scanned: 5, deleted: 2, pending: 2, busy: 1)
    expect(Storage).to receive(:cleanup_prepared_images).with(limit: 100, after_id: 0, through_id: nil).ordered.and_return(image_result(deleted: 3))
    expect(Receipts::Registrations).to receive(:cleanup_expired).with(limit: 100, after_id: 0, through_id: nil).ordered.and_return(result)
    expect(described_class).not_to receive(:perform_later)

    expect(described_class.perform_now).to eq(
      prepared_images_deleted: 3,
      registrations_scanned: 5,
      registrations_deleted: 2,
      registrations_pending: 2,
      registrations_busy: 1,
      registrations_failed: 0
    )
  end

  it '呼び出し上限を両方の限定cleanupへ渡す' do
    expect(Storage).to receive(:cleanup_prepared_images).with(limit: 10, after_id: 0, through_id: nil).and_return(image_result)
    expect(Receipts::Registrations).to receive(:cleanup_expired).with(limit: 10, after_id: 0, through_id: nil).and_return(registration_result)

    described_class.perform_now(limit: 10)
  end

  it '残りのpageだけを固定上限とともにenqueueし、完了した側は再走査しない' do
    expect(Storage).to receive(:cleanup_prepared_images).with(limit: 1, after_id: 5, through_id: 10)
      .and_return(image_result(next_after_id: 6, through_id: 10))
    expect(Receipts::Registrations).to receive(:cleanup_expired).with(limit: 1, after_id: 8, through_id: 20)
      .and_return(registration_result(through_id: 20))

    expect do
      described_class.perform_now(
        limit: 1,
        images_after_id: 5,
        images_through_id: 10,
        registrations_after_id: 8,
        registrations_through_id: 20
      )
    end.to have_enqueued_job(described_class).with(
      limit: 1,
      images_after_id: 6,
      images_through_id: 10,
      registrations_after_id: 20,
      registrations_through_id: 20
    )
  end

  it '画像が完了しても残りの受付pageをenqueueする' do
    allow(Storage).to receive(:cleanup_prepared_images).and_return(image_result(through_id: 10))
    allow(Receipts::Registrations).to receive(:cleanup_expired)
      .and_return(registration_result(next_after_id: 8, through_id: 20))

    expect do
      described_class.perform_now(limit: 1)
    end.to have_enqueued_job(described_class).with(
      limit: 1,
      images_after_id: 10,
      images_through_id: 10,
      registrations_after_id: 8,
      registrations_through_id: 20
    )
  end

  it '次pageのenqueue失敗は安全に記録して完了した回収結果を保つ' do
    allow(Storage).to receive(:cleanup_prepared_images).and_return(image_result(deleted: 1, next_after_id: 5, through_id: 10))
    allow(Receipts::Registrations).to receive(:cleanup_expired).and_return(registration_result)
    allow(described_class).to receive(:perform_later).and_raise(IOError, 'synthetic private payload')
    expect(Rails.logger).to receive(:warn).with('[UploadPreparationCleanupJob] enqueue_failed error_class=IOError')

    expect(described_class.perform_now[:prepared_images_deleted]).to eq(1)
  end

  it '次pageのenqueue拒否を記録する' do
    allow(Storage).to receive(:cleanup_prepared_images).and_return(image_result(next_after_id: 5, through_id: 10))
    allow(Receipts::Registrations).to receive(:cleanup_expired).and_return(registration_result)
    allow(described_class).to receive(:perform_later).and_return(false)
    expect(Rails.logger).to receive(:warn).with('[UploadPreparationCleanupJob] enqueue_failed')

    described_class.perform_now
  end

  it '画像cleanup失敗時に受付記録のcleanupへ進まず例外を維持する' do
    expect(Storage).to receive(:cleanup_prepared_images).and_raise(IOError, 'synthetic failure')
    expect(Receipts::Registrations).not_to receive(:cleanup_expired)

    expect { described_class.perform_now }.to raise_error(IOError, 'synthetic failure')
  end

  it '既存の全体cleanupはdry-runのまま限定cleanupを定期実行する' do
    config = YAML.load_file(Rails.root.join('config/recurring.yml')).fetch('production')

    aggregate_failures do
      expect(config.fetch('upload_preparation_cleanup')).to include(
        'class' => 'UploadPreparationCleanupJob',
        'queue' => 'default',
        'args' => [ { 'limit' => 100 } ],
        'schedule' => 'every hour at minute 17'
      )
      %w[orphan_blob_cleanup_dry_run receipt_image_purge_dry_run].each do |key|
        expect(config.fetch(key).fetch('args').first.fetch('dry_run')).to be(true)
      end
    end
  end
end
