require 'rails_helper'

RSpec.describe SystemOperations::SystemSettingDependencyLock do
  it '相互依存する外部サービス設定を同じlock groupへまとめる' do
    ai_groups = SystemSettings.dependency_lock_groups_for(
      'external_services.ai.read_timeout_seconds'
    )
    status_groups = SystemSettings.dependency_lock_groups_for(
      'external_services.down_failure_threshold'
    )

    aggregate_failures do
      expect(ai_groups).to eq([ 'external_service_ai_runtime' ])
      expect(status_groups).to eq([ 'external_service_status' ])
      expect(SystemSettings.dependency_lock_groups_for('feature.receipt_logo_display_enabled')).to eq([])
    end
  end

  it 'UserLimit override keyを対応するSystemSettingsと同じlock groupへまとめる' do
    aggregate_failures do
      expect(SystemSettings.dependency_lock_groups_for('receipt_items_per_receipt'))
        .to eq([ 'receipt_items_snapshot' ])
      expect(SystemSettings.dependency_lock_groups_for('receipt_uploads_per_day'))
        .to eq([ 'user_limit_safety' ])
      expect(SystemSettings.dependency_lock_groups_for('ocr_jobs_per_day'))
        .to eq([ 'user_limit_safety' ])
      expect(SystemSettings.dependency_lock_groups_for('ai_jobs_per_day'))
        .to eq([ 'user_limit_safety' ])
      expect(SystemSettings.dependency_lock_groups_for('storage_bytes'))
        .to eq([ 'user_limit_safety' ])
    end
  end

  it '同じdependency groupの更新blockを直列化する' do
    first_entered = Queue.new
    release_first = Queue.new
    second_entered = Queue.new
    errors = Queue.new

    first = Thread.new do
      described_class.call(groups: [ 'external_service_status' ]) do
        first_entered << true
        release_first.pop
      end
    rescue StandardError => error
      errors << error
    end
    first_entered.pop

    second = Thread.new do
      described_class.call(groups: [ 'external_service_status' ]) do
        second_entered << true
      end
    rescue StandardError => error
      errors << error
    end

    begin
      expect do
        Timeout.timeout(0.05) { second_entered.pop }
      end.to raise_error(Timeout::Error)
    ensure
      release_first << true
      [ first, second ].each(&:join)
    end

    raise errors.pop unless errors.empty?

    expect(second_entered.pop).to eq(true)
  end

  it 'dependency groupごとにdatabase advisory lockを取得する' do
    connection = SystemSetting.connection
    allow(SystemSetting).to receive(:connection).and_return(connection)
    expect(connection).to receive(:execute)
      .with(a_string_including('pg_advisory_xact_lock'))
      .and_call_original

    described_class.call(groups: [ 'external_service_status' ]) { true }
  end
end
