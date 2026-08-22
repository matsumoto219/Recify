require 'rails_helper'

RSpec.describe 'Reference pricing auto adoption fence concurrency' do
  self.use_transactional_tests = false

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
    @receipt = create(:receipt)
    @user = @receipt.user
    @run = Receipts::Processing::Runs.start(receipt: @receipt, source: 'upload').run
    Receipts::Processing::Runs.record_ocr_snapshot(@run, destination_ocr_result)
  end

  before do
    prepare_run
  end

  after do
    Receipt.where(id: @receipt&.id).destroy_all
    SystemSetting.where(key: SystemSettings::REFERENCE_PRICING_AUTO_ADOPTION_KEY).delete_all
    User.where(id: @user&.id).destroy_all
  end

  it 'writerが先にsetting rowをlockした場合はwriter完了までOFF更新を待たせる' do
    writer_entered = Queue.new
    release_writer = Queue.new
    writer_result = Queue.new
    off_completed = Queue.new
    errors = Queue.new

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_result << Receipts::Processing::ReferencePricingAutoAdoptionFence.with_locked_run(run: @run) do
          writer_entered << true
          release_writer.pop
          true
        end
      end
    rescue StandardError => error
      errors << error
    end
    writer_entered.pop

    off = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SystemSetting.find(@setting.id).update!(value: SystemSettings.stored_value(false))
        off_completed << true
      end
    rescue StandardError => error
      errors << error
    end

    begin
      expect do
        Timeout.timeout(0.05) { off_completed.pop }
      end.to raise_error(Timeout::Error)
    ensure
      release_writer << true
      [ writer, off ].each(&:join)
    end
    raise errors.pop unless errors.empty?

    aggregate_failures do
      expect(writer_result.pop).to be_enabled
      expect(off_completed.pop).to be(true)
      expect(@setting.reload.value).to eq('value' => false)
      expect(@run.reload.metadata).to have_key('reference_pricing_auto_adoption_claim')
    end
  end

  it 'OFF更新が先にsetting rowをlockした場合はwriterが最新OFFを見てyieldしない' do
    off_locked = Queue.new
    release_off = Queue.new
    writer_completed = Queue.new
    writes = Queue.new
    errors = Queue.new

    off = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        SystemSetting.transaction do
          setting = SystemSetting.lock.find(@setting.id)
          setting.update!(value: SystemSettings.stored_value(false))
          off_locked << true
          release_off.pop
        end
      end
    rescue StandardError => error
      errors << error
    end
    off_locked.pop

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = Receipts::Processing::ReferencePricingAutoAdoptionFence.with_locked_run(run: @run) do
          writes << true
          true
        end
        writer_completed << result
      end
    rescue StandardError => error
      errors << error
    end

    begin
      expect do
        Timeout.timeout(0.05) { writer_completed.pop }
      end.to raise_error(Timeout::Error)
    ensure
      release_off << true
      [ off, writer ].each(&:join)
    end
    raise errors.pop unless errors.empty?

    aggregate_failures do
      expect(writer_completed.pop.reason).to eq('current_setting_disabled')
      expect(writes).to be_empty
      expect(@run.reload.metadata).not_to have_key('reference_pricing_auto_adoption_claim')
    end
  end
end
