require 'rails_helper'

RSpec.describe ExternalServiceMonitorJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  describe '.queue_name' do
    it 'default queueを維持する' do
      expect(described_class.queue_name).to eq('default')
    end
  end

  it 'monitor例外ログへ例外本文を出さない' do
    logged_message = nil
    logger = instance_double(ActiveSupport::Logger)
    allow(logger).to receive(:warn) { |message| logged_message = message }
    allow(Rails).to receive(:logger).and_return(logger)
    allow(ExternalServices).to receive(:services_due_for_check).and_return([ :ocr ])
    allow(ExternalServices).to receive(:check_available?)
      .and_raise(StandardError, 'Bearer sk-secret https://ocr.example.test/operation/123')
    allow(ExternalServices).to receive(:mark_monitor_failure!)

    described_class.perform_now

    aggregate_failures do
      expect(logged_message).to include('service=ocr', 'class=StandardError')
      expect(logged_message).not_to include('sk-secret', 'ocr.example.test', 'operation/123')
    end
  end

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
    allow(ExternalServices).to receive(:check_available?).and_return(true)
  end

  after do
    travel_back
    Rails.cache.clear
  end

  it 'dueでないserviceはskipする' do
    described_class.perform_now

    aggregate_failures do
      expect(ExternalServices).not_to have_received(:check_available?)
    end
  end

  it 'due service だけ checker を実行する' do
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      described_class.perform_now
    end

    aggregate_failures do
      expect(ExternalServices).to have_received(:check_available?).with(:ocr).once
      expect(ExternalServices).not_to have_received(:check_available?).with(:ai)
    end
  end

  it 'AI service は静的availability成功だけでは復旧扱いにしない' do
    make_degraded(:ai)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      before_check = ExternalServices.snapshot(:ai)

      described_class.perform_now
      snapshot = ExternalServices.snapshot(:ai)

      aggregate_failures do
        expect(ExternalServices).to have_received(:check_available?).with(:ai).once
        expect(snapshot[:state]).to eq('degraded')
        expect(snapshot[:monitoring]).to eq(true)
        expect(snapshot[:consecutive_successes]).to eq(0)
        expect(snapshot[:last_error_code]).to eq('external_service_unavailable')
        expect(Time.zone.parse(snapshot[:next_check_at])).to be > Time.zone.parse(before_check[:next_check_at])
      end
    end
  end

  it 'OCR service は静的availability成功だけでは復旧扱いにしない' do
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      before_check = ExternalServices.snapshot(:ocr)

      described_class.perform_now
      snapshot = ExternalServices.snapshot(:ocr)

      aggregate_failures do
        expect(ExternalServices).to have_received(:check_available?).with(:ocr).once
        expect(snapshot[:state]).to eq('degraded')
        expect(snapshot[:monitoring]).to eq(true)
        expect(snapshot[:consecutive_successes]).to eq(0)
        expect(snapshot[:last_error_code]).to eq('external_service_unavailable')
        expect(Time.zone.parse(snapshot[:next_check_at])).to be > Time.zone.parse(before_check[:next_check_at])
      end
    end
  end

  it 'checker failure では state を維持し next_check_at を更新する' do
    allow(ExternalServices).to receive(:check_available?).with(:ocr).and_return(false)
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      before_check = ExternalServices.snapshot(:ocr)

      described_class.perform_now
      snapshot = ExternalServices.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('degraded')
        expect(snapshot[:monitoring]).to eq(true)
        expect(snapshot[:last_error_code]).to eq('external_service_unavailable')
        expect(Time.zone.parse(snapshot[:next_check_at])).to be > Time.zone.parse(before_check[:next_check_at])
      end
    end
  end

  it 'checker例外も failure 扱いにする' do
    allow(ExternalServices).to receive(:check_available?).with(:ocr).and_raise(StandardError, 'boom')
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      expect { described_class.perform_now }.not_to raise_error

      snapshot = ExternalServices.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('degraded')
        expect(snapshot[:monitoring]).to eq(true)
        expect(snapshot[:last_error_code]).to eq('external_service_unavailable')
      end
    end
  end

  private

  def make_degraded(service)
    travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
      ExternalServices.mark_failure!(service, error_code: 'external_service_unavailable')
      ExternalServices.mark_failure!(service, error_code: 'external_service_unavailable')
    end
  end

  def make_down(service)
    travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
      ExternalServices.mark_failure!(service, error_code: 'external_service_unavailable')
      ExternalServices.mark_failure!(service, error_code: 'external_service_unavailable')
      ExternalServices.mark_failure!(service, error_code: 'external_service_unavailable')
    end
  end
end
