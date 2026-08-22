require 'rails_helper'

RSpec.describe 'SystemSettings dependency lock' do
  def queue_pop(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def join_threads(*threads)
    Timeout.timeout(5) { threads.each(&:join) }
  end

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
      SystemSettings.with_dependency_lock(key: 'external_services.down_failure_threshold') do
        first_entered << true
        queue_pop(release_first)
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(first_entered)

    second = Thread.new do
      SystemSettings.with_dependency_lock(key: 'external_services.down_failure_threshold') do
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
      join_threads(first, second)
    end

    raise queue_pop(errors) unless errors.empty?

    expect(queue_pop(second_entered)).to eq(true)
  end

  it 'dependency groupごとにdatabase advisory lockを取得する' do
    connection = SystemSetting.connection
    allow(SystemSetting).to receive(:connection).and_return(connection)
    expect(connection).to receive(:execute)
      .with(a_string_including('pg_advisory_xact_lock'))
      .and_call_original

    SystemSettings.with_dependency_lock(key: 'external_services.down_failure_threshold') { true }
  end
end
