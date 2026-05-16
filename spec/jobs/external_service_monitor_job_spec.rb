require 'rails_helper'

RSpec.describe ExternalServiceMonitorJob, type: :job do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
    allow(Ocr::AvailabilityChecker).to receive(:call).and_return(true)
    allow(Ai::AvailabilityChecker).to receive(:call).and_return(true)
  end

  after do
    travel_back
    Rails.cache.clear
  end

  it 'dueでないserviceはskipする' do
    described_class.perform_now

    aggregate_failures do
      expect(Ocr::AvailabilityChecker).not_to have_received(:call)
      expect(Ai::AvailabilityChecker).not_to have_received(:call)
    end
  end

  it 'due service だけ checker を実行する' do
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      described_class.perform_now
    end

    aggregate_failures do
      expect(Ocr::AvailabilityChecker).to have_received(:call).once
      expect(Ai::AvailabilityChecker).not_to have_received(:call)
    end
  end

  it 'degraded service は checker 成功1回で ok に戻る' do
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      described_class.perform_now
      snapshot = ExternalServiceStatus.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('ok')
        expect(snapshot[:monitoring]).to eq(false)
        expect(snapshot[:next_check_at]).to be_nil
      end
    end
  end

  it 'down service は checker 成功1回目では monitoring を継続する' do
    make_down(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:06:00')) do
      described_class.perform_now
      snapshot = ExternalServiceStatus.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('down')
        expect(snapshot[:monitoring]).to eq(true)
        expect(snapshot[:consecutive_successes]).to eq(1)
      end
    end
  end

  it 'down service は checker 成功2回目で ok に戻る' do
    make_down(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:06:00')) do
      described_class.perform_now
      described_class.perform_now
      snapshot = ExternalServiceStatus.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('ok')
        expect(snapshot[:monitoring]).to eq(false)
        expect(snapshot[:next_check_at]).to be_nil
      end
    end
  end

  it 'checker failure では state を維持し next_check_at を更新する' do
    allow(Ocr::AvailabilityChecker).to receive(:call).and_return(false)
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      before_check = ExternalServiceStatus.snapshot(:ocr)

      described_class.perform_now
      snapshot = ExternalServiceStatus.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('degraded')
        expect(snapshot[:monitoring]).to eq(true)
        expect(snapshot[:last_error_code]).to eq('external_service_unavailable')
        expect(Time.zone.parse(snapshot[:next_check_at])).to be > Time.zone.parse(before_check[:next_check_at])
      end
    end
  end

  it 'checker例外も failure 扱いにする' do
    allow(Ocr::AvailabilityChecker).to receive(:call).and_raise(StandardError, 'boom')
    make_degraded(:ocr)

    travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
      expect { described_class.perform_now }.not_to raise_error

      snapshot = ExternalServiceStatus.snapshot(:ocr)

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
      ExternalServiceStatus.mark_failure!(service, error_code: 'external_service_unavailable')
      ExternalServiceStatus.mark_failure!(service, error_code: 'external_service_unavailable')
    end
  end

  def make_down(service)
    travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
      ExternalServiceStatus.mark_failure!(service, error_code: 'external_service_unavailable')
      ExternalServiceStatus.mark_failure!(service, error_code: 'external_service_unavailable')
      ExternalServiceStatus.mark_failure!(service, error_code: 'external_service_unavailable')
    end
  end
end
