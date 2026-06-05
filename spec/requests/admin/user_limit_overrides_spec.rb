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

    it 'admin自身のoverride更新を許可し、AuditLogを作成する' do
      admin = create(:user, :admin)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post limit_overrides_admin_user_path(admin),
             params: {
               key: 'receipt_uploads_per_day',
               value: '80',
               enabled: '1',
               reason: 'admin self limit tuning',
               confirmation: 'UPDATE USER LIMIT'
             }
      end.to change(AuditLog, :count).by(1)

      override = UserLimitOverride.find_by!(user: admin, key: 'receipt_uploads_per_day')
      audit_log = AuditLog.last

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(admin))
        expect(override.integer_value).to eq(80)
        expect(audit_log).to have_attributes(
          actor_user: admin,
          action: 'admin.users.limit_update',
          outcome: 'succeeded',
          target_uid: "user:#{admin.id}"
        )
      end
    end

    it '他admin targetのoverride更新は拒否する' do
      admin = create(:user, :admin)
      other_admin = create(:user, :admin)
      sign_in admin
      stub_fresh_admin_reauthentication

      expect do
        post limit_overrides_admin_user_path(other_admin),
             params: {
               key: 'receipt_uploads_per_day',
               value: '80',
               enabled: '1',
               reason: 'other admin limit tuning',
               confirmation: 'UPDATE USER LIMIT'
             }
      end.to change(AuditLog, :count).by(1)

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(other_admin))
        expect(flash[:alert]).to include('管理者ユーザー')
        expect(UserLimitOverride.where(user: other_admin)).to be_empty
        expect(AuditLog.last).to have_attributes(action: 'admin.users.limit_update', outcome: 'failed', error_code: 'admin_target_forbidden')
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

    it 'snapshot OCR/AI上限を超える明細数overrideは日本語の理由を表示して拒否する' do
      admin = create(:user, :admin)
      target = create(:user)
      sign_in admin
      stub_fresh_admin_reauthentication

      post limit_overrides_admin_user_path(target),
           params: {
             key: 'receipt_items_per_receipt',
             value: '1200',
             enabled: '1',
             reason: 'raise receipt item limit',
             confirmation: 'UPDATE USER LIMIT'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(flash[:alert]).to include('receipt_items_per_receipt の最大値を上げるには、先に snapshot OCR/AI 上限を同等以上に変更してください。')
        expect(UserLimitOverride.where(user: target, key: 'receipt_items_per_receipt')).to be_empty
        expect(AuditLog.last).to have_attributes(action: 'admin.users.limit_update', outcome: 'failed', error_code: 'receipt_items_snapshot_limit')
      end
    end

    it 'SystemSettingsのシステム上限を超えるoverrideは日本語の理由を表示して拒否する' do
      admin = create(:user, :admin)
      target = create(:user)
      create(:system_setting, key: 'limits.max_uploads_per_day', value: SystemSettings.stored_value(100))
      sign_in admin
      stub_fresh_admin_reauthentication

      post limit_overrides_admin_user_path(target),
           params: {
             key: 'receipt_uploads_per_day',
             value: '101',
             enabled: '1',
             reason: 'raise upload limit',
             confirmation: 'UPDATE USER LIMIT'
           }

      aggregate_failures do
        expect(response).to redirect_to(admin_user_path(target))
        expect(flash[:alert]).to include('UserLimitsのシステム上限を超えています')
        expect(UserLimitOverride.where(user: target, key: 'receipt_uploads_per_day')).to be_empty
        expect(AuditLog.last).to have_attributes(action: 'admin.users.limit_update', outcome: 'failed', error_code: 'user_limit_safety_max')
      end
    end
  end
end
