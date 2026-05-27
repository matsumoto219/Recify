require 'rails_helper'

RSpec.describe 'Admin user limit overrides', type: :request do
  def stub_fresh_admin_reauthentication
    allow_any_instance_of(Admin::UserLimitOverridesController).to receive(:admin_passkey_reauthenticated?).and_return(true)
    allow_any_instance_of(Admin::UserLimitOverridesController).to receive(:admin_reauthentication_context).and_return(
      method: 'passkey',
      reauthenticated_at: Time.current
    )
  end

  describe 'POST /admin/users/:id/limit_overrides' do
    it 'fresh reauthなしではSystemOperationsを呼ばずreauthへredirectする' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      allow(SystemOperations).to receive(:update_user_limit)

      post limit_overrides_admin_user_path(target),
           params: { key: 'receipt_uploads_per_day', value: '75', enabled: '1', reason: 'support request', confirmation: 'UPDATE USER LIMIT' }

      aggregate_failures do
        expect(response).to redirect_to(new_admin_passkey_reauthentication_path(return_to: admin_user_path(target)))
        expect(SystemOperations).not_to have_received(:update_user_limit)
        expect(session.to_hash.to_json).not_to include('support request', 'UPDATE USER LIMIT')
      end
    end

    it 'reason blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:update_user_limit)

      post limit_overrides_admin_user_path(target),
           params: { key: 'receipt_uploads_per_day', value: '75', enabled: '1', reason: ' ', confirmation: 'UPDATE USER LIMIT' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).not_to have_received(:update_user_limit)
      end
    end

    it 'confirmation blankではSystemOperationsを呼ばない' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication
      allow(SystemOperations).to receive(:update_user_limit)

      post limit_overrides_admin_user_path(target),
           params: { key: 'receipt_uploads_per_day', value: '75', enabled: '1', reason: 'support request', confirmation: ' ' }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(SystemOperations).not_to have_received(:update_user_limit)
      end
    end

    it 'fresh reauth + reason + confirmationでSystemOperations経由で実行する' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication
      result = SystemOperations::Result.new(success: true)
      allow(SystemOperations).to receive(:update_user_limit).and_return(result)

      post limit_overrides_admin_user_path(target),
           params: {
             key: 'receipt_uploads_per_day',
             value: '75',
             enabled: '1',
             expires_at: '2026-06-01T12:00',
             reason: 'support request',
             confirmation: 'UPDATE USER LIMIT'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(flash[:notice]).to include('ユーザー別上限を更新しました')
        expect(SystemOperations).to have_received(:update_user_limit).with(
          user: target,
          key: 'receipt_uploads_per_day',
          value: '75',
          enabled: '1',
          expires_at: '2026-06-01T12:00',
          actor: admin,
          reason: 'support request',
          request: kind_of(ActionDispatch::Request),
          reauthentication: hash_including(method: 'passkey', reauthenticated_at: kind_of(ActiveSupport::TimeWithZone)),
          confirmation: 'UPDATE USER LIMIT'
        )
      end
    end

    it '実SystemOperations経由でoverrideを更新し、AuditLogを作成する' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post limit_overrides_admin_user_path(target),
             params: {
               key: 'receipt_uploads_per_day',
               value: '75',
               enabled: '1',
               reason: 'support request',
               confirmation: 'UPDATE USER LIMIT'
             }
      end.to change(AuditLog, :count).by(1)

      override = UserLimitOverride.find_by!(user: target, key: 'receipt_uploads_per_day')
      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(override.integer_value).to eq(75)
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'admin.users.limit_update',
          outcome: 'succeeded',
          target_uid: "user:#{target.id}"
        )
        expect(audit_log.attributes.to_json).not_to include('credential_id', 'public_key', 'challenge', 'session_uid', 'raw_response', 'prompt')
      end
    end

    it 'SystemOperations失敗時はalertで戻す' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication

      post limit_overrides_admin_user_path(target),
           params: {
             key: 'secret.provider_api_key',
             value: '75',
             enabled: '1',
             reason: 'bad key',
             confirmation: 'UPDATE USER LIMIT'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(flash[:alert]).to include('対象上限')
        expect(UserLimitOverride.where(user: target)).to be_empty
        expect(AuditLog.last).to have_attributes(action: 'admin.users.limit_update', outcome: 'failed', error_code: 'unknown_key')
      end
    end
  end
end
