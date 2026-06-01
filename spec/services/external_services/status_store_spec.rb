require 'rails_helper'

RSpec.describe ExternalServices::StatusStore do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
  end

  after do
    travel_back
    Rails.cache.clear
  end

  describe '.state' do
    it '初期状態は ok を返す' do
      expect(described_class.state(:ocr)).to eq('ok')
    end

    it '未知の service では ArgumentError を返す' do
      expect { described_class.state(:unknown) }.to raise_error(ArgumentError, 'Unsupported service: unknown')
    end
  end

  describe '.snapshot' do
    it '初期状態のスナップショットを返す' do
      snapshot = described_class.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('ok')
        expect(snapshot[:monitoring]).to eq(false)
        expect(snapshot[:consecutive_failures]).to eq(0)
        expect(snapshot[:consecutive_successes]).to eq(0)
        expect(snapshot[:last_error_code]).to be_nil
        expect(snapshot[:first_failed_at]).to be_nil
        expect(snapshot[:last_checked_at]).to be_nil
        expect(snapshot[:next_check_at]).to be_nil
      end
    end
  end

  describe '.due_for_check?' do
    it 'monitoring false の場合は false を返す' do
      expect(described_class.due_for_check?(:ocr)).to eq(false)
    end

    it 'next_check_at が未来の場合は false を返す' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')

        expect(described_class.due_for_check?(:ocr)).to eq(false)
      end
    end

    it 'monitoring true かつ next_check_at を過ぎている場合は true を返す' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
        expect(described_class.due_for_check?(:ocr)).to eq(true)
      end
    end
  end

  describe '.services_due_for_check' do
    it '期限を過ぎた monitoring service だけを返す' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
        expect(described_class.services_due_for_check).to eq([ :ocr ])
      end
    end
  end

  describe '.mark_failure!' do
    it '1回目の外部サービス系失敗では ok のまま' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('ok')
          expect(snapshot[:monitoring]).to eq(false)
          expect(snapshot[:consecutive_failures]).to eq(1)
          expect(snapshot[:consecutive_successes]).to eq(0)
          expect(snapshot[:last_error_code]).to eq('external_service_unavailable')
          expect(snapshot[:first_failed_at]).to be_present
          expect(snapshot[:last_checked_at]).to be_present
        end
      end
    end

    it '5分以内に2回失敗すると degraded になる' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:03:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('degraded')
          expect(snapshot[:monitoring]).to eq(true)
          expect(snapshot[:consecutive_failures]).to eq(2)
          expect(snapshot[:next_check_at]).to be_present
        end
      end
    end

    it '5分以内に3回失敗すると down になる' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:02:00')) do
        described_class.mark_failure!(:ocr, error_code: 'ocr_timeout')
      end

      travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('down')
          expect(snapshot[:monitoring]).to eq(true)
          expect(snapshot[:consecutive_failures]).to eq(3)
          expect(snapshot[:next_check_at]).to be_present
        end
      end
    end

    it 'down 後の追加失敗では next_check_at を後ろ倒ししない' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end
      travel_to(Time.zone.parse('2026-04-15 10:01:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end
      travel_to(Time.zone.parse('2026-04-15 10:02:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      down_snapshot = described_class.snapshot(:ocr)

      travel_to(Time.zone.parse('2026-04-15 10:03:00')) do
        described_class.mark_failure!(:ocr, error_code: 'ocr_timeout')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('down')
          expect(snapshot[:consecutive_failures]).to eq(3)
          expect(snapshot[:next_check_at]).to eq(down_snapshot[:next_check_at])
          expect(snapshot[:last_error_code]).to eq('ocr_timeout')
          expect(snapshot[:last_checked_at]).to be_present
        end
      end
    end

    it '対象外エラーでは状態を劣化させない' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'ocr_unreadable')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('ok')
          expect(snapshot[:monitoring]).to eq(false)
          expect(snapshot[:consecutive_failures]).to eq(0)
          expect(snapshot[:last_error_code]).to be_nil
          expect(snapshot[:last_checked_at]).to be_nil
        end
      end
    end

    it '失敗ウィンドウを超えたら failure カウントをリセットする' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:06:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('ok')
          expect(snapshot[:consecutive_failures]).to eq(1)
          expect(snapshot[:first_failed_at]).to be_present
        end
      end
    end
  end

  describe '.mark_monitor_failure!' do
    it 'degraded 状態を維持しながら next_check_at を次回へ進める' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
        before_check = described_class.snapshot(:ocr)

        described_class.mark_monitor_failure!(:ocr, error_code: 'ocr_timeout')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('degraded')
          expect(snapshot[:monitoring]).to eq(true)
          expect(snapshot[:last_error_code]).to eq('ocr_timeout')
          expect(Time.zone.parse(snapshot[:next_check_at])).to be > Time.zone.parse(before_check[:next_check_at])
        end
      end
    end

    it 'down 状態を維持しながら next_check_at を次回へ進める' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:06:00')) do
        before_check = described_class.snapshot(:ocr)

        described_class.mark_monitor_failure!(:ocr, error_code: 'external_service_unavailable')
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('down')
          expect(snapshot[:monitoring]).to eq(true)
          expect(snapshot[:consecutive_successes]).to eq(0)
          expect(Time.zone.parse(snapshot[:next_check_at])).to be > Time.zone.parse(before_check[:next_check_at])
        end
      end
    end
  end

  describe '.mark_success!' do
    it 'ok 状態で成功すると failure をリセットする' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:01:00')) do
        described_class.mark_success!(:ocr)
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('ok')
          expect(snapshot[:monitoring]).to eq(false)
          expect(snapshot[:consecutive_failures]).to eq(0)
          expect(snapshot[:consecutive_successes]).to eq(1)
          expect(snapshot[:last_error_code]).to be_nil
          expect(snapshot[:first_failed_at]).to be_nil
          expect(snapshot[:next_check_at]).to be_nil
        end
      end
    end

    it 'degraded 状態で成功すると ok に戻る' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end
      travel_to(Time.zone.parse('2026-04-15 10:02:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:03:00')) do
        described_class.mark_success!(:ocr)
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('ok')
          expect(snapshot[:monitoring]).to eq(false)
          expect(snapshot[:consecutive_failures]).to eq(0)
          expect(snapshot[:consecutive_successes]).to eq(1)
          expect(snapshot[:next_check_at]).to be_nil
        end
      end
    end

    it 'down 状態では連続成功2回で ok に戻る' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end
      travel_to(Time.zone.parse('2026-04-15 10:01:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end
      travel_to(Time.zone.parse('2026-04-15 10:02:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      travel_to(Time.zone.parse('2026-04-15 10:03:00')) do
        described_class.mark_success!(:ocr)
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('down')
          expect(snapshot[:monitoring]).to eq(true)
          expect(snapshot[:consecutive_successes]).to eq(1)
          expect(snapshot[:consecutive_failures]).to eq(0)
        end
      end

      travel_to(Time.zone.parse('2026-04-15 10:04:00')) do
        described_class.mark_success!(:ocr)
        snapshot = described_class.snapshot(:ocr)

        aggregate_failures do
          expect(snapshot[:state]).to eq('ok')
          expect(snapshot[:monitoring]).to eq(false)
          expect(snapshot[:consecutive_successes]).to eq(2)
          expect(snapshot[:next_check_at]).to be_nil
        end
      end
    end
  end

  describe '.reset!' do
    it '状態を初期化する' do
      travel_to(Time.zone.parse('2026-04-15 10:00:00')) do
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
        described_class.mark_failure!(:ocr, error_code: 'external_service_unavailable')
      end

      described_class.reset!(:ocr)
      snapshot = described_class.snapshot(:ocr)

      aggregate_failures do
        expect(snapshot[:state]).to eq('ok')
        expect(snapshot[:monitoring]).to eq(false)
        expect(snapshot[:consecutive_failures]).to eq(0)
        expect(snapshot[:consecutive_successes]).to eq(0)
        expect(snapshot[:last_error_code]).to be_nil
        expect(snapshot[:first_failed_at]).to be_nil
        expect(snapshot[:last_checked_at]).to be_nil
        expect(snapshot[:next_check_at]).to be_nil
      end
    end
  end

  describe '.external_error?' do
    it '外部サービス系エラーでは true を返す' do
      expect(described_class.external_error?('external_service_unavailable')).to eq(true)
      expect(described_class.external_error?('ocr_timeout')).to eq(true)
      expect(described_class.external_error?('ai_timeout')).to eq(true)
    end

    it '対象外エラーでは false を返す' do
      expect(described_class.external_error?('ocr_unreadable')).to eq(false)
      expect(described_class.external_error?('input_invalid')).to eq(false)
      expect(described_class.external_error?('image_corrupted')).to eq(false)
      expect(described_class.external_error?('ai_invalid_response')).to eq(false)
      expect(described_class.external_error?(nil)).to eq(false)
    end
  end
end
