require 'rails_helper'

RSpec.describe 'Receipt registration operation cleanup' do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  def operation(issued_at: 25.hours.ago, state: 'failed', receipts: [])
    ReceiptRegistrationOperation.create!(
      user: user,
      operation_key: SecureRandom.hex(32),
      kind: 'manual',
      state: state,
      input_fingerprint: SecureRandom.hex(32),
      attempt_key: SecureRandom.hex(16),
      issued_at: issued_at,
      expires_at: issued_at + 24.hours,
      receipt_ids: receipts.map(&:id),
      accepted_at: state == 'accepted' ? issued_at + 1.minute : nil
    )
  end

  it '期限後の受付記録だけを削除しReceiptや利用回数を削除しない' do
    receipt = create(:receipt, user: user)
    Usage.consume_manual_receipt!(user: user)
    expired = operation(state: 'accepted', receipts: [ receipt ])
    current = operation(issued_at: Time.current)

    result = Receipts::Registrations.cleanup_expired

    aggregate_failures do
      expect(result.deleted).to eq(1)
      expect(ReceiptRegistrationOperation.exists?(expired.id)).to be(false)
      expect(ReceiptRegistrationOperation.exists?(current.id)).to be(true)
      expect(receipt.reload).to be_persisted
      expect(UsageCounter.find_by!(user: user).used_count).to eq(1)
    end
  end

  it '未確定画像が残る受付記録を保持する' do
    record = operation
    blob = ActiveStorage::Blob.create!(
      key: SecureRandom.hex(20),
      filename: 'synthetic.png',
      byte_size: 10,
      checksum: 'dGVzdA==',
      content_type: 'image/png',
      service_name: ActiveStorage::Blob.service.name,
      metadata: { 'upload_preparation' => { 'user_id' => user.id, 'registration_key' => record.operation_key } }
    )

    result = Receipts::Registrations.cleanup_expired

    expect(result.pending).to eq(1)
    expect(ReceiptRegistrationOperation.exists?(record.id)).to be(true)
    expect(ActiveStorage::Blob.exists?(blob.id)).to be(true)
  end

  it '実行中lockがあるexpired処理中記録をskipする' do
    record = operation(state: 'processing')

    Storage.with_upload_operation_lock(key: "#{user.id}:#{record.operation_key}") do
      result = Receipts::Registrations.cleanup_expired
      expect(result.busy).to eq(1)
      expect(ReceiptRegistrationOperation.exists?(record.id)).to be(true)
    end

    expect(Receipts::Registrations.cleanup_expired.deleted).to eq(1)
  end

  it 'limitより先に期限で絞り込み受付期限内の記録に妨げられない' do
    operation(issued_at: Time.current)
    expired = operation

    expect(Receipts::Registrations.cleanup_expired(limit: 1).deleted).to eq(1)
    expect(ReceiptRegistrationOperation.exists?(expired.id)).to be(false)
  end

  it '画像待ちの先頭を越えて巡回し、新しい受付は次の巡回へ残す' do
    pending = operation
    following = operation
    ActiveStorage::Blob.create!(
      key: SecureRandom.hex(20),
      filename: 'synthetic.png',
      byte_size: 10,
      checksum: 'dGVzdA==',
      content_type: 'image/png',
      service_name: ActiveStorage::Blob.service.name,
      metadata: { 'upload_preparation' => { 'user_id' => user.id, 'registration_key' => pending.operation_key } }
    )

    first = Receipts::Registrations.cleanup_expired(limit: 1)
    inserted = operation
    second = Receipts::Registrations.cleanup_expired(limit: 1, after_id: first.next_after_id, through_id: first.through_id)

    aggregate_failures do
      expect(first.pending).to eq(1)
      expect(first.scanned).to eq(1)
      expect(first.next_after_id).to eq(pending.id)
      expect(first.through_id).to eq(following.id)
      expect(second.deleted).to eq(1)
      expect(second.next_after_id).to be_nil
      expect(ReceiptRegistrationOperation.exists?(pending.id)).to be(true)
      expect(ReceiptRegistrationOperation.exists?(following.id)).to be(false)
      expect(ReceiptRegistrationOperation.exists?(inserted.id)).to be(true)
    end
    expect(Receipts::Registrations.cleanup_expired.deleted).to eq(1)
  end

  it '削除失敗でもcursorを進めて次の定期巡回で再試行する' do
    failed = operation
    following = operation
    allow_any_instance_of(ReceiptRegistrationOperation).to receive(:destroy!).and_wrap_original do |method|
      raise ActiveRecord::RecordNotDestroyed, 'synthetic private payload' if method.receiver.id == failed.id

      method.call
    end
    expect(Rails.logger).to receive(:warn).with('[ReceiptRegistration] cleanup_failed error_class=ActiveRecord::RecordNotDestroyed')

    first = Receipts::Registrations.cleanup_expired(limit: 1)
    second = Receipts::Registrations.cleanup_expired(limit: 1, after_id: first.next_after_id, through_id: first.through_id)

    expect(first.failed).to eq(1)
    expect(second.deleted).to eq(1)
    expect(ReceiptRegistrationOperation.exists?(following.id)).to be(false)
    allow_any_instance_of(ReceiptRegistrationOperation).to receive(:destroy!).and_call_original
    expect(Receipts::Registrations.cleanup_expired.deleted).to eq(1)
  end

  it '不正なcursorは受付を削除せず拒否する' do
    record = operation

    [ { after_id: -1 }, { after_id: '1' }, { through_id: -1 }, { after_id: 2, through_id: 1 } ].each do |cursor|
      expect { Receipts::Registrations.cleanup_expired(**cursor) }.to raise_error(ArgumentError, 'invalid cleanup cursor')
    end
    expect(ReceiptRegistrationOperation.exists?(record.id)).to be(true)
  end
end
