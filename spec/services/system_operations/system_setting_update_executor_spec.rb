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
      user_id: actor.id,
      session_version: actor.session_version,
      expires_at: reauthenticated_at + Admin.passkey_reauth_window_duration,
      credential_id: 'credential-secret',
      public_key: 'public-key-secret',
      challenge: 'challenge-secret'
    }
  end

  around do |example|
    travel_to(Time.zone.parse('2026-05-27 10:00:00')) { example.run }
  end

  describe '.call' do
    it '既定値と同じ通常保存もDB overrideとして維持する' do
      result = described_class.call(
        key: 'feature.receipt_logo_display_enabled',
        value: 'false',
        actor: actor,
        reason: 'pin current default explicitly',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.fetch('feature.receipt_logo_display_enabled')).to have_attributes(
          current_value: false,
          source: 'db'
        )
      end
    end

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

    it '依存設定を対応するdependency lock内で更新する' do
      allow(SystemOperations::SystemSettingDependencyLock).to receive(:call).and_call_original

      result = described_class.call(
        key: 'external_services.ai.read_timeout_seconds',
        value: '120',
        actor: actor,
        reason: 'adjust AI read timeout',
        request: request,
        reauthentication: reauthentication,
        confirmation: '1'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemOperations::SystemSettingDependencyLock).to have_received(:call)
          .with(groups: [ 'external_service_ai_runtime' ])
      end
    end

    it '依存する設定の並行更新で不正な組み合わせを保存しない' do
      create(
        :system_setting,
        key: 'external_services.down_failure_threshold',
        value: SystemSettings.stored_value(5)
      )
      create(
        :system_setting,
        key: 'external_services.degraded_failure_threshold',
        value: SystemSettings.stored_value(2)
      )

      model_validated = Queue.new
      release_writes = Queue.new
      allow(SystemSettings).to receive(:validate_stored_value!).and_wrap_original do |original, *args|
        result = original.call(*args)
        model_validated << true
        release_writes.pop
        result
      end

      results = Queue.new
      errors = Queue.new
      first_thread = Thread.new do
        results << described_class.call(
          key: 'external_services.degraded_failure_threshold',
          value: '4',
          actor: actor,
          reason: 'raise degraded threshold',
          request: request,
          reauthentication: reauthentication,
          confirmation: '1'
        )
      rescue StandardError => error
        errors << error
      end

      second_thread = Thread.new do
        results << described_class.call(
          key: 'external_services.down_failure_threshold',
          value: '3',
          actor: actor,
          reason: 'lower down threshold',
          request: request,
          reauthentication: reauthentication,
          confirmation: '1'
        )
      rescue StandardError => error
        errors << error
      end

      begin
        Timeout.timeout(0.1) { 2.times { model_validated.pop } }
      rescue Timeout::Error
        nil
      ensure
        2.times { release_writes << true }
      end
      [ first_thread, second_thread ].each(&:join)

      raise errors.pop unless errors.empty?

      update_results = 2.times.map { results.pop }
      degraded = SystemSettings.limit_for('external_services.degraded_failure_threshold')
      down = SystemSettings.limit_for('external_services.down_failure_threshold')

      aggregate_failures do
        expect(update_results.count(&:success?)).to eq(1)
        expect(update_results.count(&:failure?)).to eq(1)
        expect(update_results.find(&:failure?).error_code)
          .to eq('external_service_status_threshold_relationship')
        expect(degraded).to be < down
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

    it 'レシート画像保持期間の変更はhigh riskとして監査ログに残す' do
      result = described_class.call(
        key: 'retention.receipt_images_days',
        value: '30',
        actor: actor,
        reason: 'extend receipt image purge retention',
        request: request,
        reauthentication: reauthentication,
        confirmation: '1'
      )

      audit_log = AuditLog.last

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.limit_for('retention.receipt_images_days')).to eq(30)
        expect(audit_log).to have_attributes(
          action: 'system_settings.update',
          outcome: 'succeeded',
          target_uid: 'retention.receipt_images_days',
          reason: 'extend receipt image purge retention'
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

    it 'SystemSettingsの再認証windowを超過したHIGH設定更新を拒否する' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(1))

      result = described_class.call(
        key: 'retention.orphan_blobs_hours',
        value: '72',
        actor: actor,
        reason: 'expired high risk update',
        request: request,
        reauthentication: reauthentication.merge(reauthenticated_at: 2.minutes.ago),
        confirmation: '1'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('reauthentication_required')
        expect(SystemSettings.limit_for('retention.orphan_blobs_hours')).to eq(48)
      end
    end

    it 'SystemSettingsの再認証window内ならHIGH設定更新を許可する' do
      create(:system_setting, key: 'security.admin_passkey_reauth_window_minutes', value: SystemSettings.stored_value(15))

      result = described_class.call(
        key: 'retention.orphan_blobs_hours',
        value: '72',
        actor: actor,
        reason: 'fresh high risk update',
        request: request,
        reauthentication: reauthentication.merge(reauthenticated_at: 10.minutes.ago),
        confirmation: '1'
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.limit_for('retention.orphan_blobs_hours')).to eq(72)
        expect(AuditLog.last.metadata).to include('reauthenticated' => true)
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

    it 'snapshot item上限を明細上限未満へ下げる更新を拒否する' do
      create(
        :system_setting,
        key: 'limits.receipt_items_per_receipt',
        value: SystemSettings.stored_value(500)
      )

      result = described_class.call(
        key: 'limits.snapshot_ocr_items_max',
        value: '100',
        actor: actor,
        reason: 'lower OCR snapshot item limit',
        request: request,
        reauthentication: reauthentication,
        confirmation: '1'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('receipt_items_snapshot_limit')
        expect(SystemSettings.limit_for('limits.snapshot_ocr_items_max')).to eq(1000)
      end
    end

    it 'activeなuser overrideを下回るsnapshot item上限への更新を拒否する' do
      user = create(:user)
      create(:system_setting, key: 'limits.snapshot_ocr_items_max', value: SystemSettings.stored_value(1500))
      create(:system_setting, key: 'limits.snapshot_ai_normalized_items_max', value: SystemSettings.stored_value(1500))
      create(
        :user_limit_override,
        user: user,
        key: 'receipt_items_per_receipt',
        value: { 'value' => 1200 }
      )

      result = described_class.call(
        key: 'limits.snapshot_ocr_items_max',
        value: '1000',
        actor: actor,
        reason: 'unsafe snapshot lowering with active override',
        request: request,
        reauthentication: reauthentication,
        confirmation: '1'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('receipt_items_snapshot_limit')
        expect(SystemSettings.limit_for('limits.snapshot_ocr_items_max')).to eq(1500)
        expect(AuditLog.last).to have_attributes(outcome: 'failed', error_code: 'receipt_items_snapshot_limit')
      end
    end

    it '店舗名casing参照行数がsnapshot OCR行数上限を超える更新を拒否する' do
      create(:system_setting, key: 'limits.store_name_casing_context_lines_max', value: SystemSettings.stored_value(0))
      create(:system_setting, key: 'limits.snapshot_ocr_lines_max', value: SystemSettings.stored_value(10))

      result = described_class.call(
        key: 'limits.store_name_casing_context_lines_max',
        value: '11',
        actor: actor,
        reason: 'raise store casing context line limit',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('store_name_casing_snapshot_ocr_lines_limit')
        expect(SystemSettings.limit_for('limits.store_name_casing_context_lines_max')).to eq(0)
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'store_name_casing_snapshot_ocr_lines_limit',
          target_uid: 'limits.store_name_casing_context_lines_max'
        )
      end
    end

    it 'snapshot OCR行数上限を店舗名casing参照行数未満へ下げる更新を拒否する' do
      create(:system_setting, key: 'limits.store_name_casing_context_lines_max', value: SystemSettings.stored_value(20))

      result = described_class.call(
        key: 'limits.snapshot_ocr_lines_max',
        value: '10',
        actor: actor,
        reason: 'lower snapshot ocr line limit',
        request: request,
        reauthentication: reauthentication,
        confirmation: '1'
      )

      aggregate_failures do
        expect(result).to be_failure
        expect(result.error_code).to eq('snapshot_ocr_lines_store_name_casing_limit')
        expect(SystemSettings.limit_for('limits.snapshot_ocr_lines_max')).to eq(150)
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'failed',
          error_code: 'snapshot_ocr_lines_store_name_casing_limit',
          target_uid: 'limits.snapshot_ocr_lines_max'
        )
      end
    end

    it '店舗名casing参照行数がsnapshot OCR行数上限以下なら更新できる' do
      create(:system_setting, key: 'limits.snapshot_ocr_lines_max', value: SystemSettings.stored_value(20))

      result = described_class.call(
        key: 'limits.store_name_casing_context_lines_max',
        value: '20',
        actor: actor,
        reason: 'align store casing context line limit',
        request: request,
        reauthentication: reauthentication
      )

      aggregate_failures do
        expect(result).to be_success
        expect(SystemSettings.limit_for('limits.store_name_casing_context_lines_max')).to eq(20)
        expect(AuditLog.last).to have_attributes(
          action: 'system_settings.update',
          outcome: 'succeeded',
          target_uid: 'limits.store_name_casing_context_lines_max'
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
