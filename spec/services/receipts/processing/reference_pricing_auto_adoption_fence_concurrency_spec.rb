require 'rails_helper'

RSpec.describe 'Reference pricing auto adoption fence concurrency' do
  self.use_transactional_tests = false

  def queue_pop(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def join_threads(*threads)
    Timeout.timeout(5) { threads.each(&:join) }
  end

  def wait_for_database_lock(backend_pid, thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      wait_event_type = ActiveRecord::Base.connection.select_value(
        "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(backend_pid)}"
      )
      return if wait_event_type == 'Lock'

      raise 'database lock waiter terminated before blocking' unless thread.alive?
      raise Timeout::Error, 'database lock waiter did not block' if
        Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      Thread.pass
    end
  end

  def destination_ocr_result
    raw_json = JSON.parse(
      Rails.root.join('spec/fixtures/ocr/ocr_azure_measurement_line_group_destination_anonymized.json').read
    )

    Ocr::ResponseParser.new(response: raw_json, provider: :fixture).call
  end

  def prepare_run
    SystemSetting.where(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY).delete_all
    @setting = create(
      :system_setting,
      key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY,
      value: SystemSettings.stored_value(true)
    )
    @receipt = create(:receipt, :with_image)
    @user = @receipt.user
    @run = Receipts::Processing::Runs.start(receipt: @receipt, source: 'upload').run
    Receipts::Processing::Runs.record_ocr_snapshot(@run, destination_ocr_result)
  end

  before do
    prepare_run
  end

  after do
    blob_ids = ActiveStorage::Attachment.where(
      record_type: 'Receipt',
      record_id: @receipt&.id,
      name: 'image'
    ).pluck(:blob_id)
    Receipt.where(id: @receipt&.id).destroy_all
    ActiveStorage::Blob.where(id: blob_ids).find_each(&:purge)
    SystemSetting.where(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY).delete_all
    User.where(id: @user&.id).destroy_all
  end

  it 'writerが先にsetting rowをlockした場合はwriter完了までOFF更新を待たせる' do
    writer_entered = Queue.new
    release_writer = Queue.new
    writer_result = Queue.new
    off_attempted = Queue.new
    off_backend = Queue.new
    off_completed = Queue.new
    errors = Queue.new

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_result << Receipts::Processing::ReferencePricingAutoAdoptionFence.with_locked_run(run: @run) do
          writer_entered << true
          queue_pop(release_writer)
          true
        end
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(writer_entered)

    off = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        off_backend << ActiveRecord::Base.connection.raw_connection.backend_pid
        setting = SystemSetting.find(@setting.id)
        off_attempted << true
        setting.update!(value: SystemSettings.stored_value(false))
        off_completed << true
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(off_attempted)
    wait_for_database_lock(queue_pop(off_backend), off)

    begin
      expect(off_completed).to be_empty
    ensure
      release_writer << true
      join_threads(writer, off)
    end
    raise queue_pop(errors) unless errors.empty?

    aggregate_failures do
      expect(queue_pop(writer_result)).to be_enabled
      expect(queue_pop(off_completed)).to be(true)
      expect(@setting.reload.value).to eq('value' => false)
      expect(@run.reload.metadata).to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'OFF更新が先にsetting rowをlockした場合はwriterが最新OFFを見てyieldしない' do
    off_locked = Queue.new
    release_off = Queue.new
    writer_completed = Queue.new
    writer_attempted = Queue.new
    writer_backend = Queue.new
    writes = Queue.new
    errors = Queue.new

    off = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SystemSetting.transaction do
          setting = SystemSetting.lock.find(@setting.id)
          setting.update!(value: SystemSettings.stored_value(false))
          off_locked << true
          queue_pop(release_off)
        end
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(off_locked)

    allow(SystemSettings).to receive(:with_dependency_lock).and_wrap_original do |original, key:, &operation|
      writer_attempted << true
      original.call(key:, &operation)
    end

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_backend << ActiveRecord::Base.connection.raw_connection.backend_pid
        result = Receipts::Processing::ReferencePricingAutoAdoptionFence.with_locked_run(run: @run) do
          writes << true
          true
        end
        writer_completed << result
      end
    rescue StandardError => error
      errors << error
    end
    queue_pop(writer_attempted)
    wait_for_database_lock(queue_pop(writer_backend), writer)

    begin
      expect(writer_completed).to be_empty
    ensure
      release_off << true
      join_threads(off, writer)
    end
    raise queue_pop(errors) unless errors.empty?

    aggregate_failures do
      expect(queue_pop(writer_completed).reason).to eq('current_setting_disabled')
      expect(writes).to be_empty
      expect(@run.reload.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end
end
