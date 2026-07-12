require 'rails_helper'

RSpec.describe ExternalServices do
  describe '.services' do
    it 'StatusStoreのservice一覧を返す' do
      expect(described_class.services).to eq(%i[ocr ai])
    end
  end

  describe '.state and predicates' do
    it '合成後の状態参照を親入口から公開する' do
      allow(ExternalServices::StatusStore).to receive(:snapshot).with(:ocr).and_return(state: 'ok')
      allow(ExternalServices::StatusStore).to receive(:monitoring?).with(:ocr).and_return(false)
      allow(ExternalServices::StatusStore).to receive(:due_for_check?).with(:ocr).and_return(false)

      aggregate_failures do
        expect(described_class.state(:ocr)).to eq('ok')
        expect(described_class.ok?(:ocr)).to eq(true)
        expect(described_class.degraded?(:ocr)).to eq(false)
        expect(described_class.down?(:ocr)).to eq(false)
        expect(described_class.monitoring?(:ocr)).to eq(false)
        expect(described_class.due_for_check?(:ocr)).to eq(false)
      end
    end

    it 'SystemSettings停止中はdown扱いにする' do
      create(:system_setting, key: 'operations.ocr_enabled', value: described_class_setting(false))

      aggregate_failures do
        expect(described_class.state(:ocr)).to eq('down')
        expect(described_class.ok?(:ocr)).to eq(false)
        expect(described_class.down?(:ocr)).to eq(true)
      end
    end

    it 'ENV停止中はdown扱いにする' do
      with_env('RECEIPT_AI_ENABLED' => 'false') do
        aggregate_failures do
          expect(described_class.state(:ai)).to eq('down')
          expect(described_class.down?(:ai)).to eq(true)
        end
      end
    end

    it 'SystemSettingsが有効でもOCRのENV kill switchを優先する' do
      create(:system_setting, key: 'operations.ocr_enabled', value: described_class_setting(true))

      with_env('RECEIPT_OCR_ENABLED' => 'false') do
        aggregate_failures do
          expect(described_class.state(:ocr)).to eq('down')
          expect(described_class.down?(:ocr)).to eq(true)
          expect(described_class.snapshot(:ocr)).to include(
            disabled: true,
            source: 'env',
            reason: 'RECEIPT_OCR_ENABLED'
          )
        end
      end
    end
  end

  describe '.snapshot and .snapshots' do
    it '合成済みsnapshotを親入口から公開する' do
      ocr_snapshot = { state: 'ok' }
      ai_snapshot = { state: 'down' }

      allow(ExternalServices::StatusStore).to receive(:snapshot).with(:ocr).and_return(ocr_snapshot)
      allow(ExternalServices::StatusStore).to receive(:snapshot).with(:ai).and_return(ai_snapshot)

      aggregate_failures do
        expect(described_class.snapshot(:ocr)).to include(state: 'ok', disabled: false, source: 'status_store')
        expect(described_class.snapshots).to include(
          ocr: include(state: 'ok', disabled: false),
          ai: include(state: 'down', disabled: false)
        )
      end
    end

    it 'SystemSettings停止中のsource/reasonをsnapshotに含める' do
      create(:system_setting, key: 'operations.ai_enabled', value: described_class_setting(false))

      expect(described_class.snapshot(:ai)).to include(
        state: 'down',
        disabled: true,
        source: 'system_setting',
        reason: 'operations.ai_enabled',
        setting_key: 'operations.ai_enabled',
        env_key: 'RECEIPT_AI_ENABLED'
      )
    end

    it 'SystemSettings取得失敗時はfail-closedで停止中snapshotにする' do
      allow(SystemSettings).to receive(:enabled?)
        .with('operations.ai_enabled')
        .and_raise(SystemSettings::ValidationError, 'invalid_feature_flag')

      expect(described_class.snapshot(:ai)).to include(
        state: 'down',
        disabled: true,
        source: 'system_setting',
        reason: 'operations.ai_enabled'
      )
    end
  end

  describe '.services_due_for_check' do
    it 'StatusStoreへ委譲する' do
      allow(ExternalServices::StatusStore).to receive(:services_due_for_check).and_return([ :ocr ])

      expect(described_class.services_due_for_check).to eq([ :ocr ])
    end
  end

  describe '.mark_success!' do
    it 'StatusStoreへ委譲する' do
      allow(ExternalServices::StatusStore).to receive(:mark_success!).with(:ocr).and_return(true)

      expect(described_class.mark_success!(:ocr)).to eq(true)
    end
  end

  describe '.mark_failure!' do
    it 'StatusStoreへ委譲する' do
      allow(ExternalServices::StatusStore).to receive(:mark_failure!)
        .with(:ocr, error_code: 'ocr_timeout', reason: nil, detail: nil)
        .and_return(true)

      expect(described_class.mark_failure!(:ocr, error_code: 'ocr_timeout')).to eq(true)
    end
  end

  describe '.mark_monitor_failure!' do
    it 'StatusStoreへ委譲する' do
      allow(ExternalServices::StatusStore).to receive(:mark_monitor_failure!)
        .with(:ocr, error_code: 'external_service_unavailable', reason: nil, detail: nil)
        .and_return(true)

      expect(described_class.mark_monitor_failure!(:ocr, error_code: 'external_service_unavailable')).to eq(true)
    end
  end

  describe '.reset!' do
    it 'service指定ありならそのserviceだけresetする' do
      allow(ExternalServices::StatusStore).to receive(:reset!).with(:ocr).and_return(true)

      expect(described_class.reset!(:ocr)).to eq(true)
    end

    it 'service指定なしなら全serviceをresetする' do
      allow(ExternalServices::StatusStore).to receive(:reset!).and_return(true)

      described_class.reset!

      aggregate_failures do
        expect(ExternalServices::StatusStore).to have_received(:reset!).with(:ocr)
        expect(ExternalServices::StatusStore).to have_received(:reset!).with(:ai)
      end
    end
  end

  describe '.external_error?' do
    it 'error_code文字列をStatusStoreへ委譲する' do
      allow(ExternalServices::StatusStore).to receive(:external_error?).with('ocr_timeout').and_return(true)

      expect(described_class.external_error?('ocr_timeout')).to eq(true)
    end

    it 'error_codeを持つobjectも扱う' do
      error = double(error_code: 'ai_api_error')

      allow(ExternalServices::StatusStore).to receive(:external_error?).with('ai_api_error').and_return(true)

      expect(described_class.external_error?(error)).to eq(true)
    end
  end

  describe '.unavailable_detail' do
    it '停止中のsource/reasonをsafe detailとして返す' do
      create(:system_setting, key: 'operations.ocr_enabled', value: described_class_setting(false))

      expect(described_class.unavailable_detail(:ocr, provider: 'azure_document_intelligence', phase: 'preflight')).to include(
        service: 'ocr',
        provider: 'azure_document_intelligence',
        phase: 'preflight',
        disabled: true,
        source: 'system_setting',
        reason: 'operations.ocr_enabled'
      )
    end

    it '利用可能ならnilを返す' do
      expect(described_class.unavailable_detail(:ocr)).to be_nil
    end
  end

  describe '.status_snapshot' do
    it 'StatusSnapshotへ委譲する' do
      payload = { upload: { allowed: true } }

      allow(ExternalServices::StatusSnapshot).to receive(:call)
        .with(include_details: true)
        .and_return(payload)

      expect(described_class.status_snapshot(include_details: true)).to eq(payload)
    end
  end

  describe '.switch_debug_state' do
    it 'DebugStateSwitcherへ委譲する' do
      result = { service: 'ocr', requested_state: 'down' }

      allow(ExternalServices::DebugStateSwitcher).to receive(:call)
        .with(service: 'ocr', state: 'down')
        .and_return(result)

      expect(described_class.switch_debug_state(service: 'ocr', state: 'down')).to eq(result)
    end

    it '子実装の非公開例外をfacadeの公開例外へ変換する' do
      allow(ExternalServices::DebugStateSwitcher).to receive(:call)
        .and_raise(ExternalServices::DebugStateSwitcher::NotAvailableError)

      expect { described_class.switch_debug_state(service: 'ocr', state: 'down') }
        .to raise_error(ExternalServices::DebugSwitchNotAvailableError)
    end
  end

  describe '.debug_switch_available?' do
    it 'DebugStateSwitcherへ委譲する' do
      allow(ExternalServices::DebugStateSwitcher).to receive(:available?).and_return(false)

      expect(described_class.debug_switch_available?).to eq(false)
    end
  end

  describe '.check_available?' do
    it 'OCR checkerを呼ぶ' do
      allow(ReceiptOcrService).to receive(:available?).and_return(true)

      expect(described_class.check_available?(:ocr)).to eq(true)
      expect(ReceiptOcrService).to have_received(:available?)
    end

    it 'AI checkerを呼ぶ' do
      allow(ReceiptAiEnrichmentService).to receive(:available?).and_return(true)

      expect(described_class.check_available?('ai')).to eq(true)
      expect(ReceiptAiEnrichmentService).to have_received(:available?)
    end

    it '停止中はcheckerを呼ばずfalseを返す' do
      create(:system_setting, key: 'operations.ocr_enabled', value: described_class_setting(false))
      allow(ReceiptOcrService).to receive(:available?)

      aggregate_failures do
        expect(described_class.check_available?(:ocr)).to eq(false)
        expect(ReceiptOcrService).not_to have_received(:available?)
      end
    end

    it 'SystemSettings取得失敗時はcheckerを呼ばずfalseを返す' do
      allow(SystemSettings).to receive(:enabled?)
        .with('operations.ocr_enabled')
        .and_raise(SystemSettings::UnknownKeyError, 'operations.ocr_enabled')
      allow(ReceiptOcrService).to receive(:available?)

      aggregate_failures do
        expect(described_class.check_available?(:ocr)).to eq(false)
        expect(ReceiptOcrService).not_to have_received(:available?)
      end
    end

    it '未知serviceを明示的に弾く' do
      expect { described_class.check_available?(:storage) }
        .to raise_error(ArgumentError, 'Unsupported service: storage')
    end
  end

  def described_class_setting(value)
    SystemSettings.stored_value(value)
  end

  def with_env(overrides)
    original = overrides.keys.to_h { |key| [ key, ENV[key] ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
