require 'rails_helper'

RSpec.describe SystemOperations::SystemSettingUpdateExecutor do
  include ActiveSupport::Testing::TimeHelpers

  let(:actor) { create(:user, :admin) }
  let(:request) { instance_double(ActionDispatch::Request, request_id: 'request-id', remote_ip: '127.0.0.1', user_agent: 'System Setting Spec') }
  let(:reauthenticated_at) { Time.current }
  let(:reauthentication) do
    {
      method: 'passkey',
      reauthenticated_at: reauthenticated_at,
      credential_id: 'credential-secret',
      public_key: 'public-key-secret',
      challenge: 'challenge-secret'
    }
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  describe '.call' do
    it 'editable keyを作成し、updated_by_userとsuccess auditを保存する' do
      result = described_class.call(
        key: 'feature.receipt_logo_display_enabled',
        value: 'true',
        actor: actor,
        reason: 'enable logo display',
        request: request,
        reauthentication: reauthentication
      )

      setting = SystemSetting.find_by!(key: 'feature.receipt_logo_display_enabled')
      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(result.setting).to eq(setting)
        expect(result.value).to eq(true)
        expect(setting.value).to eq('value' => true)
        expect(setting.updated_by_user).to eq(actor)
        expect(audit_log).to have_attributes(
          actor_user: actor,
          actor_kind: 'admin',
          action: 'system_settings.update',
          outcome: 'succeeded',
          target_type: 'SystemSetting',
          target_id: setting.id,
          target_uid: 'feature.receipt_logo_display_enabled',
          reason: 'enable logo display',
          request_id: 'request-id',
          user_agent: 'System Setting Spec'
        )
        expect(audit_log.metadata).to include(
          'key' => 'feature.receipt_logo_display_enabled',
          'category' => 'feature_flag',
          'value_type' => 'boolean',
          'risk_level' => 'low',
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey',
          'reauthenticated_at' => reauthenticated_at.iso8601
        )
        expect(audit_log.before_state).to eq('value' => false, 'source' => 'default')
        expect(audit_log.after_state).to eq('value' => true, 'source' => 'db')
        expect(audit_log.attributes.to_json).not_to include('credential-secret', 'challenge-secret', 'public-key-secret')
      end
    end

    it '既存DB値を更新し、before_stateに旧値を残す' do
      create(
        :system_setting,
        key: 'limits.receipt_upload_soft_limit',
        value: SystemSettings.stored_value(100),
        updated_by_user: create(:user, :admin)
      )

      result = described_class.call(
        key: 'limits.receipt_upload_soft_limit',
        value: '250',
        actor: actor,
        reason: 'raise soft limit',
        request: request,
        reauthentication: reauthentication
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.value_for('limits.receipt_upload_soft_limit')).to eq(250)
        expect(audit_log.before_state).to eq('value' => 100, 'source' => 'db')
        expect(audit_log.after_state).to eq('value' => 250, 'source' => 'db')
      end
    end

    it 'orphan blob保持期間の変更はhigh riskとして監査ログに残す' do
      result = described_class.call(
        key: 'retention.orphan_blobs_hours',
        value: '72',
        actor: actor,
        reason: 'extend orphan blob dry-run window',
        request: request,
        reauthentication: reauthentication,
        confirmation: '1'
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.limit_for('retention.orphan_blobs_hours')).to eq(72)
        expect(audit_log).to have_attributes(
          action: 'system_settings.update',
          outcome: 'succeeded',
          target_uid: 'retention.orphan_blobs_hours',
          reason: 'extend orphan blob dry-run window'
        )
        expect(audit_log.metadata).to include(
          'category' => 'retention',
          'risk_level' => 'high',
          'reauthenticated' => true,
          'reauthentication_method' => 'passkey'
        )
      end
    end

    it 'unknown keyを拒否し、failed auditを残す' do
      result = described_class.call(
        key: 'secret.provider_api_key',
        value: 'secret',
        actor: actor,
        reason: 'bad key',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('unknown_key')
        expect(SystemSetting.find_by(key: 'secret.provider_api_key')).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'unknown_key',
          target_uid: nil
        )
        expect(AuditLog.last.metadata.to_json).not_to include('secret')
      end
    end

    it 'reason blankを拒否する' do
      result = described_class.call(
        key: 'feature.receipt_logo_display_enabled',
        value: 'true',
        actor: actor,
        reason: ' ',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('reason_required')
        expect(SystemSetting.find_by(key: 'feature.receipt_logo_display_enabled')).to be_nil
        expect(AuditLog.last.error_code).to eq('reason_required')
      end
    end

    it 'reauthentication nilを拒否する' do
      result = described_class.call(
        key: 'feature.receipt_logo_display_enabled',
        value: 'true',
        actor: actor,
        reason: 'missing reauth',
        request: request,
        reauthentication: nil
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('reauthentication_required')
        expect(AuditLog.last.metadata).not_to include('reauthenticated' => true)
      end
    end

    it 'integer min/max違反を拒否する' do
      result = described_class.call(
        key: 'limits.receipt_upload_soft_limit',
        value: '1001',
        actor: actor,
        reason: 'too high',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('above_max')
        expect(SystemSetting.find_by(key: 'limits.receipt_upload_soft_limit')).to be_nil
        expect(AuditLog.last.error_code).to eq('above_max')
      end
    end

    it '明細上限がsnapshot OCR/AI上限を超える更新を拒否する' do
      result = described_class.call(
        key: 'limits.receipt_items_per_receipt',
        value: '1200',
        actor: actor,
        reason: 'raise receipt item limit',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('receipt_items_snapshot_limit')
        expect(SystemSetting.find_by(key: 'limits.receipt_items_per_receipt')).to be_nil
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'receipt_items_snapshot_limit',
          target_uid: 'limits.receipt_items_per_receipt'
        )
      end
    end

    it 'snapshot OCR/AI上限を先に上げた場合は明細上限を更新できる' do
      create(:system_setting, key: 'limits.snapshot_ocr_items_max', value: SystemSettings.stored_value(1500))
      create(:system_setting, key: 'limits.snapshot_ai_normalized_items_max', value: SystemSettings.stored_value(1500))

      result = described_class.call(
        key: 'limits.receipt_items_per_receipt',
        value: '1200',
        actor: actor,
        reason: 'raise receipt item limit after snapshot limits',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.limit_for('limits.receipt_items_per_receipt')).to eq(1200)
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'succeeded',
          target_uid: 'limits.receipt_items_per_receipt'
        )
      end
    end

    it 'requires_confirmation設定ではconfirmationを要求する' do
      with_extra_definition(
        SystemSettings::Definition.new(
          key: 'feature.high_risk_enabled',
          category: 'feature_flag',
          value_type: 'boolean',
          default: false,
          editable: true,
          risk_level: 'high',
          requires_confirmation: true
        )
      ) do
        result = described_class.call(
          key: 'feature.high_risk_enabled',
          value: 'true',
          actor: actor,
          reason: 'enable high risk flag',
          request: request,
          reauthentication: reauthentication,
          confirmation: '0'
        )

        aggregate_failures do
          expect(result).to be_failure
          expect(result.error_code).to eq('confirmation_required')
          expect(SystemSetting.find_by(key: 'feature.high_risk_enabled')).to be_nil
          expect(AuditLog.last.error_code).to eq('confirmation_required')
        end
      end
    end

    it 'enum / percentage / user_allowlistをcastして保存できる' do
      with_extra_definitions(
        [
          SystemSettings::Definition.new(
            key: 'feature.rollout_percentage',
            category: 'rollout',
            value_type: 'percentage',
            default: BigDecimal('0'),
            editable: true,
            risk_level: 'medium'
          ),
          SystemSettings::Definition.new(
            key: 'feature.mode',
            category: 'feature_flag',
            value_type: 'enum',
            default: 'off',
            editable: true,
            risk_level: 'low',
            allowed_values: %w[off beta on]
          ),
          SystemSettings::Definition.new(
            key: 'feature.user_allowlist',
            category: 'rollout',
            value_type: 'user_allowlist',
            default: [],
            editable: true,
            risk_level: 'medium'
          )
        ]
      ) do
        percentage = described_class.call(
          key: 'feature.rollout_percentage',
          value: '12.5',
          actor: actor,
          reason: 'set percentage',
          request: request,
          reauthentication: reauthentication
        )
        enum = described_class.call(
          key: 'feature.mode',
          value: 'beta',
          actor: actor,
          reason: 'set mode',
          request: request,
          reauthentication: reauthentication
        )
        allowlist = described_class.call(
          key: 'feature.user_allowlist',
          value: "1\n2, 2 3",
          actor: actor,
          reason: 'set allowlist',
          request: request,
          reauthentication: reauthentication
        )

        aggregate_failures do
          expect(percentage).to be_success
          expect(enum).to be_success
          expect(allowlist).to be_success
          expect(SystemSetting.find_by!(key: 'feature.rollout_percentage').value).to eq('value' => '12.5')
          expect(SystemSetting.find_by!(key: 'feature.mode').value).to eq('value' => 'beta')
          expect(SystemSetting.find_by!(key: 'feature.user_allowlist').value).to eq('value' => %w[1 2 3])
        end
      end
    end
  end

  def with_extra_definition(definition, &block)
    with_extra_definitions([ definition ], &block)
  end

  def with_extra_definitions(extra_definitions)
    original_definitions = SystemSettings.definitions
    merged_definitions = original_definitions.merge(extra_definitions.index_by(&:key))

    allow(SystemSettings).to receive(:definitions).and_return(merged_definitions)
    yield
  ensure
    allow(SystemSettings).to receive(:definitions).and_call_original
  end
end
