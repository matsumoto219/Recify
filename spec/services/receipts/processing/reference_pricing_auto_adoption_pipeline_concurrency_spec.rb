require 'rails_helper'

RSpec.describe 'Reference pricing automatic adoption pipeline concurrency' do
  self.use_transactional_tests = false
  WAIT_SECONDS = 5

  def queue_pop(queue)
    Timeout.timeout(WAIT_SECONDS) { queue.pop }
  end

  def join_threads(*threads)
    Timeout.timeout(WAIT_SECONDS) { threads.each(&:join) }
  end

  def wait_for_dependency_lock(thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_SECONDS
    loop do
      locations = Array(thread.backtrace_locations)
      return if thread.status == 'sleep' && locations.any? do |location|
        location.absolute_path&.end_with?('/app/services/system_settings/dependency_lock.rb')
      end

      raise 'dependency lock waiter terminated before blocking' unless thread.alive?
      raise Timeout::Error, 'dependency lock waiter did not block' if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end

  def destination_ocr_result
    raw = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )
    Ocr::ResponseParser.new(response: raw, provider: :fixture).call
  end

  def finalize_decision
    Receipts::Processing::Contracts::FinalizeDecision.new(
      finalize_strategy: :ocr_only,
      error_code: nil,
      error_message: nil,
      receipt_attributes: {},
      ocr_result: nil,
      ai_result: nil,
      metadata: {}
    )
  end

  def update_adoption_setting(value)
    SystemOperations.update_setting(
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: value.to_s,
      actor: @admin,
      reason: 'concurrency stop guarantee',
      request: @request,
      reauthentication: @reauthentication,
      confirmation: '1'
    )
  end

  def reset_adoption_setting
    SystemOperations.reset_setting(
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      actor: @admin,
      reason: 'concurrency reset stop guarantee',
      request: @request,
      reauthentication: @reauthentication,
      confirmation: '1'
    )
  end

  before do
    SystemSetting.where(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY).delete_all
    @setting = create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(true)
    )
    @receipt = create(:receipt, :processing, :with_image, country_region: 'JPN')
    @user = @receipt.user
    @admin = create(:user, :admin)
    @request = instance_double(
      ActionDispatch::Request,
      request_id: 'a1-concurrency-request',
      remote_ip: '127.0.0.1',
      user_agent: 'A1 Concurrency Spec'
    )
    @reauthentication = {
      method: 'passkey',
      reauthenticated_at: Time.current,
      user_id: @admin.id,
      session_version: @admin.session_version,
      expires_at: Time.current + Admin.passkey_reauth_window_duration
    }
    @run = Receipts::Processing.start(receipt: @receipt, source: 'upload').run
    Receipts::Processing.record_ocr_snapshot(@run, destination_ocr_result)
    Receipts::Processing.record_finalize_decision(@run, finalize_decision)
  end

  after do
    Receipt.where(id: @receipt&.id).destroy_all
    SystemSetting.where(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY).delete_all
    AuditLog.where(actor_user_id: @admin&.id).delete_all
    User.where(id: @admin&.id).destroy_all
    User.where(id: @user&.id).destroy_all
  end

  it 'writer先行時はauthority・claim・run successのcommitまでOFF成功応答を待たせる' do
    amount_entered = Queue.new
    release_amount = Queue.new
    writer_completed = Queue.new
    off_attempted = Queue.new
    off_completed = Queue.new
    errors = Queue.new
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      amount_entered << true
      queue_pop(release_amount)
      original.call(**kwargs)
    end

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_completed << Receipts::Processing.run_finalize(@run)
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(amount_entered)

    allow(SystemSettings).to receive(:with_dependency_lock).and_wrap_original do |original, key:, &operation|
      off_attempted << true
      original.call(key:, &operation)
    end

    off = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        off_completed << update_adoption_setting(false)
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(off_attempted)
    wait_for_dependency_lock(off)

    begin
      expect(off_completed).to be_empty
    ensure
      release_amount << true
      join_threads(writer, off)
    end
    raise queue_pop(errors) unless errors.empty?

    aggregate_failures do
      expect(queue_pop(writer_completed).next_step).to eq(:done)
      expect(queue_pop(off_completed)).to be_success
      expect(@receipt.reload.receipt_items.sole.pricing_source_kind).to eq('reference_quantity_price')
      expect(@run.reload.status).to eq('succeeded')
      expect(@run.metadata).to have_key('reference_pricing_auto_adoption_claim')
      expect(@setting.reload.value).to eq('value' => false)
    end
  end

  it 'reset先行時はwriterが最新default OFFを確認して通常Finalizeだけをcommitする' do
    off_locked = Queue.new
    release_off = Queue.new
    writer_completed = Queue.new
    writer_attempted = Queue.new
    off_completed = Queue.new
    errors = Queue.new
    invocation_count = 0
    invocation_mutex = Mutex.new
    allow(SystemSettings).to receive(:with_dependency_lock).and_wrap_original do |original, key:, &operation|
      invocation = invocation_mutex.synchronize do
        invocation_count += 1
      end
      if invocation == 1
        original.call(key:) do
          result = operation.call
          off_locked << true
          queue_pop(release_off)
          result
        end
      else
        writer_attempted << true
        original.call(key:, &operation)
      end
    end

    off = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        off_completed << reset_adoption_setting
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(off_locked)

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_completed << Receipts::Processing.run_finalize(@run)
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(writer_attempted)
    wait_for_dependency_lock(writer)

    begin
      expect(writer_completed).to be_empty
    ensure
      release_off << true
      join_threads(off, writer)
    end
    raise queue_pop(errors) unless errors.empty?

    aggregate_failures do
      expect(queue_pop(off_completed)).to be_success
      expect(queue_pop(writer_completed).next_step).to eq(:done)
      expect(@receipt.reload.receipt_items).to be_empty
      expect(@run.reload.status).to eq('succeeded')
      expect(@run.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
      expect(SystemSetting.find_by(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY)).to be_nil
    end
  end

  it '同じrunの並行Finalizeはauthorityとclaimを最大1件だけcommitする' do
    amount_entered = Queue.new
    release_amount = Queue.new
    second_started = Queue.new
    results = Queue.new
    errors = Queue.new
    allow(ReceiptAmountService).to receive(:call).and_wrap_original do |original, **kwargs|
      amount_entered << true
      queue_pop(release_amount)
      original.call(**kwargs)
    end

    first = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        results << Receipts::Processing.run_finalize(ReceiptAnalysisRun.find(@run.id))
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(amount_entered)

    allow(SystemSettings).to receive(:with_dependency_lock).and_wrap_original do |original, key:, &operation|
      second_started << true
      original.call(key:, &operation)
    end

    second = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        results << Receipts::Processing.run_finalize(ReceiptAnalysisRun.find(@run.id))
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(second_started)
    wait_for_dependency_lock(second)

    begin
      expect(results).to be_empty
    ensure
      release_amount << true
      join_threads(first, second)
    end
    raise queue_pop(errors) unless errors.empty?

    outcomes = 2.times.map { queue_pop(results) }
    aggregate_failures do
      expect(outcomes.count { |result| result.next_step == :done }).to eq(1)
      expect(outcomes.count { |result| result.next_step == :skipped }).to eq(1)
      expect(@receipt.reload.receipt_items.count).to eq(1)
      expect(@receipt.receipt_items.sole.pricing_source_kind).to eq('reference_quantity_price')
      expect(@run.reload.status).to eq('succeeded')
      expect(@run.metadata.fetch('reference_pricing_auto_adoption_claim')).to include(
        'schema_version' => 'reference_pricing_auto_adoption_claim_v1'
      )
    end
  end
end
