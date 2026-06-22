# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SystemOperations::ReceiptModerationExecutor do
  include ActiveSupport::Testing::TimeHelpers

  let(:actor) { create(:user, :admin) }
  let(:request) { instance_double(ActionDispatch::Request, request_id: 'request-id', remote_ip: '192.0.2.50', user_agent: 'Receipt Moderation Spec') }
  let(:reauthenticated_at) { Time.current }
  let(:reauthentication) do
    {
      method: 'passkey',
      reauthenticated_at: reauthenticated_at,
      credential_id: 'credential-secret',
      challenge: 'challenge-secret'
    }
  end

  around do |example|
    travel_to(Time.zone.parse('2026-06-23 10:00:00')) { example.run }
  end

  it 'quarantineを実行してAuditLogに最小情報を保存する' do
    receipt = create(:receipt, :with_image, :completed, total_amount: 1200)
    source = create(:security_event)
    blob_id = receipt.image.blob.id

    result = described_class.call(
      operation: 'quarantine',
      receipt: receipt,
      actor: actor,
      reason: 'policy violation',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'QUARANTINE RECEIPT',
      source_security_event: source
    )

    audit_log = AuditLog.last

    aggregate_failures do
      expect(result).to be_success
      expect(receipt.reload).to have_attributes(
        moderation_status: 'quarantined',
        quarantined_by: actor,
        quarantine_reason: 'policy violation',
        quarantine_source_security_event: source
      )
      expect(receipt.image).to be_attached
      expect(ActiveStorage::Blob.exists?(blob_id)).to be(true)
      expect(audit_log).to have_attributes(
        actor_user: actor,
        action: 'admin.receipts.quarantine',
        outcome: 'succeeded',
        target_type: 'Receipt',
        target_id: receipt.id,
        target_uid: "receipt:#{receipt.public_id}",
        reason: 'policy violation',
        request_id: 'request-id',
        user_agent: 'Receipt Moderation Spec'
      )
      expect(audit_log.metadata).to include(
        'operation' => 'quarantine',
        'receipt_id' => receipt.id,
        'receipt_public_id' => receipt.public_id,
        'target_user_id' => receipt.user_id,
        'before_status' => 'active',
        'after_status' => 'quarantined',
        'image_attached' => true,
        'image_purged' => false,
        'source_security_event_id' => source.id,
        'reauthenticated' => true,
        'reauthentication_method' => 'passkey'
      )
      expect(audit_log.attributes.to_json).not_to include('credential-secret', 'challenge-secret', 'raw_text', 'ocr', 'ai')
    end
  end

  it 'releaseを実行して隔離履歴を残したまま通常表示に戻す' do
    receipt = create(:receipt, :quarantined, quarantine_reason: 'policy violation')

    result = described_class.call(
      operation: 'release',
      receipt: receipt,
      actor: actor,
      reason: 'false positive',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'RELEASE RECEIPT'
    )

    aggregate_failures do
      expect(result).to be_success
      expect(receipt.reload).to have_attributes(
        moderation_status: 'active',
        quarantine_released_by: actor,
        quarantine_released_reason: 'false positive'
      )
      expect(receipt.quarantined_at).to be_present
      expect(receipt.quarantine_reason).to eq('policy violation')
      expect(AuditLog.last).to have_attributes(
        action: 'admin.receipts.release',
        outcome: 'succeeded',
        target_uid: "receipt:#{receipt.public_id}",
        reason: 'false positive'
      )
    end
  end

  it 'fresh passkey reauthentication必須' do
    receipt = create(:receipt)

    result = described_class.call(
      operation: 'quarantine',
      receipt: receipt,
      actor: actor,
      reason: 'policy violation',
      request: request,
      reauthentication: {},
      confirmation: 'QUARANTINE RECEIPT'
    )

    aggregate_failures do
      expect(result).to have_attributes(success: false, error_code: 'reauthentication_required')
      expect(receipt.reload).to be_moderation_active
      expect(AuditLog.last).to have_attributes(action: 'admin.receipts.quarantine', outcome: 'failed')
    end
  end

  it 'reasonとconfirmation phrase必須' do
    receipt = create(:receipt)

    blank_reason = described_class.call(
      operation: 'quarantine',
      receipt: receipt,
      actor: actor,
      reason: ' ',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'QUARANTINE RECEIPT'
    )
    wrong_confirmation = described_class.call(
      operation: 'quarantine',
      receipt: receipt,
      actor: actor,
      reason: 'policy violation',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'WRONG'
    )

    aggregate_failures do
      expect(blank_reason).to have_attributes(success: false, error_code: 'reason_required')
      expect(wrong_confirmation).to have_attributes(success: false, error_code: 'confirmation_required')
      expect(receipt.reload).to be_moderation_active
    end
  end

  it 'active以外のquarantineとquarantined以外のreleaseを拒否する' do
    quarantined = create(:receipt, :quarantined)
    active = create(:receipt)

    quarantine_again = described_class.call(
      operation: 'quarantine',
      receipt: quarantined,
      actor: actor,
      reason: 'policy violation',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'QUARANTINE RECEIPT'
    )
    release_active = described_class.call(
      operation: 'release',
      receipt: active,
      actor: actor,
      reason: 'false positive',
      request: request,
      reauthentication: reauthentication,
      confirmation: 'RELEASE RECEIPT'
    )

    aggregate_failures do
      expect(quarantine_again).to have_attributes(success: false, error_code: 'receipt_already_quarantined')
      expect(release_active).to have_attributes(success: false, error_code: 'receipt_not_quarantined')
    end
  end
end
