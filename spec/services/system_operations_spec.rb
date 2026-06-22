require 'rails_helper'

RSpec.describe SystemOperations do
  describe '.execute_receipt_analysis_cleanup' do
    it 'ReceiptAnalysisCleanupExecutorへ委譲する親入口である' do
      allow(SystemOperations::ReceiptAnalysisCleanupExecutor).to receive(:call).and_return(SystemOperations::Result.new(success: true))

      result = described_class.execute_receipt_analysis_cleanup(
        operation: 'stale_cleanup',
        actor: build_stubbed(:user, :admin),
        reason: 'cleanup',
        cutoff: Time.current,
        limit: 10,
        request: nil,
        reauthentication: { method: 'passkey', reauthenticated_at: Time.current }
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemOperations::ReceiptAnalysisCleanupExecutor).to have_received(:call).with(
          operation: 'stale_cleanup',
          actor: kind_of(User),
          reason: 'cleanup',
          cutoff: kind_of(ActiveSupport::TimeWithZone),
          limit: 10,
          request: nil,
          reauthentication: hash_including(method: 'passkey')
        )
      end
    end
  end

  describe '.update_setting' do
    it 'SystemSettingUpdateExecutorへ委譲する親入口である' do
      allow(SystemOperations::SystemSettingUpdateExecutor).to receive(:call).and_return(SystemOperations::Result.new(success: true))

      result = described_class.update_setting(
        key: 'feature.receipt_logo_display_enabled',
        value: 'true',
        actor: build_stubbed(:user, :admin),
        reason: 'update setting',
        request: nil,
        reauthentication: { method: 'passkey', reauthenticated_at: Time.current },
        confirmation: '1'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemOperations::SystemSettingUpdateExecutor).to have_received(:call).with(
          key: 'feature.receipt_logo_display_enabled',
          value: 'true',
          actor: kind_of(User),
          reason: 'update setting',
          request: nil,
          reauthentication: hash_including(method: 'passkey'),
          confirmation: '1'
        )
      end
    end
  end

  describe '.execute_user_operation' do
    it 'UserOperationExecutorへ委譲する親入口である' do
      allow(SystemOperations::UserOperationExecutor).to receive(:call).and_return(SystemOperations::Result.new(success: true))
      target_user = build_stubbed(:user)

      result = described_class.execute_user_operation(
        operation: 'lock_user',
        user: target_user,
        actor: build_stubbed(:user, :admin),
        reason: 'support request',
        request: nil,
        reauthentication: { method: 'passkey', reauthenticated_at: Time.current },
        confirmation: 'LOCK USER'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemOperations::UserOperationExecutor).to have_received(:call).with(
          operation: 'lock_user',
          user: target_user,
          actor: kind_of(User),
          reason: 'support request',
          request: nil,
          reauthentication: hash_including(method: 'passkey'),
          confirmation: 'LOCK USER'
        )
      end
    end
  end

  describe '.update_user_limit' do
    it 'UserLimitUpdateExecutorへ委譲する親入口である' do
      allow(SystemOperations::UserLimitUpdateExecutor).to receive(:call).and_return(SystemOperations::Result.new(success: true))
      target_user = build_stubbed(:user)

      result = described_class.update_user_limit(
        user: target_user,
        key: 'receipt_uploads_per_day',
        value: '75',
        enabled: '1',
        expires_at: nil,
        actor: build_stubbed(:user, :admin),
        reason: 'support limit update',
        request: nil,
        reauthentication: { method: 'passkey', reauthenticated_at: Time.current },
        confirmation: 'UPDATE USER LIMIT'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemOperations::UserLimitUpdateExecutor).to have_received(:call).with(
          user: target_user,
          key: 'receipt_uploads_per_day',
          value: '75',
          enabled: '1',
          expires_at: nil,
          actor: kind_of(User),
          reason: 'support limit update',
          request: nil,
          reauthentication: hash_including(method: 'passkey'),
          confirmation: 'UPDATE USER LIMIT'
        )
      end
    end
  end

  describe '.execute_receipt_moderation_operation' do
    it 'ReceiptModerationExecutorへ委譲する親入口である' do
      allow(SystemOperations::ReceiptModerationExecutor).to receive(:call).and_return(SystemOperations::Result.new(success: true))
      receipt = build_stubbed(:receipt)
      security_event = build_stubbed(:security_event)

      result = described_class.execute_receipt_moderation_operation(
        operation: 'quarantine',
        receipt: receipt,
        actor: build_stubbed(:user, :admin),
        reason: 'policy violation',
        request: nil,
        reauthentication: { method: 'passkey', reauthenticated_at: Time.current },
        confirmation: 'QUARANTINE RECEIPT',
        source_security_event: security_event
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemOperations::ReceiptModerationExecutor).to have_received(:call).with(
          operation: 'quarantine',
          receipt: receipt,
          actor: kind_of(User),
          reason: 'policy violation',
          request: nil,
          reauthentication: hash_including(method: 'passkey'),
          confirmation: 'QUARANTINE RECEIPT',
          source_security_event: security_event
        )
      end
    end
  end

  describe '.user_limit_update_confirmation_text' do
    it 'UserLimitUpdateExecutorの確認文言を親入口から公開する' do
      expect(described_class.user_limit_update_confirmation_text).to eq('UPDATE USER LIMIT')
    end
  end
end
