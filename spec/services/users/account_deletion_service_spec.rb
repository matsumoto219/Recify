require 'rails_helper'

RSpec.describe Users::AccountDeletionService do
  def attach_avatar(user)
    user.avatar.attach(
      io: File.open(Rails.root.join('spec/fixtures/files/receipt_sample.jpg')),
      filename: 'avatar.jpg',
      content_type: 'image/jpeg'
    )
  end

  def create_user_session_for(user)
    UserSession.create!(
      user: user,
      session_uid_digest: "digest-#{SecureRandom.hex(16)}",
      session_version: user.session_version,
      started_at: Time.current,
      last_seen_at: Time.current
    )
  end

  it 'userを削除し、dependent destroy / nullify を既存退会方針に合わせて実行する' do
    user = create(:user, email: 'delete-service@example.com')
    attach_avatar(user)
    receipt = create(:receipt, :with_image, user: user)
    owned_run = create(:receipt_analysis_run, :succeeded, receipt: receipt)
    passkey = create(:passkey, user: user, credential_id: 'credential-secret', public_key: 'public-key-secret')
    user_session = create_user_session_for(user)
    notification = create(:notification, user: user)
    other_user = create(:user)
    external_receipt = create(:receipt, user: other_user)
    requested_run = create(:receipt_analysis_run, :admin_retry, receipt: external_receipt, requested_by_user: user)
    avatar_attachment_id = user.avatar.attachment.id
    receipt_image_attachment_id = receipt.image.attachment.id
    blob_ids = [ user.avatar.blob.id, receipt.image.blob.id ]
    blob_keys = [ user.avatar.blob.key, receipt.image.blob.key ]
    allow(ActiveStorage::PurgeJob).to receive(:perform_later).and_return(false)

    result = described_class.call(user: user)

    aggregate_failures do
      expect(result).to be_success
      expect(result.summary).to include(
        user_id: user.id,
        admin: false,
        guest: false,
        receipts_count: 1,
        passkeys_count: 1,
        user_sessions_count: 1,
        notifications_count: 1,
        avatar_attached: true
      )
      expect(User.where(id: user.id)).not_to exist
      expect(Receipt.where(id: receipt.id)).not_to exist
      expect(ReceiptAnalysisRun.where(id: owned_run.id)).not_to exist
      expect(Passkey.where(id: passkey.id)).not_to exist
      expect(UserSession.where(id: user_session.id)).not_to exist
      expect(Notification.where(id: notification.id)).not_to exist
      expect(requested_run.reload.requested_by_user_id).to be_nil
      expect(ActiveStorage::Attachment.where(id: avatar_attachment_id)).not_to exist
      expect(ActiveStorage::Attachment.where(id: receipt_image_attachment_id)).not_to exist
      expect(ActiveStorage::Blob.where(id: blob_ids)).to be_empty
      expect(blob_keys).to all(satisfy { |key| !ActiveStorage::Blob.service.exist?(key) })
    end
  end

  it 'summaryにcredential/session/token/secret相当の値を含めない' do
    user = create(:user, email: 'safe-summary@example.com')
    passkey = create(:passkey, user: user, credential_id: 'credential-secret', public_key: 'public-key-secret')
    user_session = create_user_session_for(user)
    encrypted_password = user.encrypted_password

    result = described_class.call(user: user)
    payload = result.summary.to_json

    aggregate_failures do
      expect(payload).not_to include('safe-summary@example.com')
      expect(payload).not_to include(encrypted_password)
      expect(payload).not_to include(passkey.credential_id)
      expect(payload).not_to include(passkey.public_key)
      expect(payload).not_to include(user_session.session_uid_digest)
      expect(payload).not_to include('token', 'secret', 'credential')
      expect(result.summary[:email_digest]).to be_present
    end
  end

  it '本人退会用途ではAuditLogを作成しない' do
    user = create(:user)

    expect do
      described_class.call(user: user, actor: user, audit: false)
    end.not_to change(AuditLog, :count)
  end

  it 'Users親入口から呼び出せる' do
    user = create(:user)

    result = Users.delete_account(user: user)

    expect(result.summary[:user_id]).to eq(user.id)
    expect(User.where(id: user.id)).not_to exist
  end

  it 'destroy失敗時は例外を返し、userを残す' do
    user = create(:user)
    allow(user).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed.new('blocked', user))

    expect do
      described_class.call(user: user)
    end.to raise_error(ActiveRecord::RecordNotDestroyed)

    expect(User.where(id: user.id)).to exist
  end
end
