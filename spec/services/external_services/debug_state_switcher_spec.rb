require 'rails_helper'

RSpec.describe ExternalServices::DebugStateSwitcher do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    Rails.cache.clear
  end

  after do
    Rails.cache.clear
  end

  describe '.call' do
    it 'serviceをdegraded状態に切り替える' do
      result = described_class.call(service: 'ocr', state: 'degraded')

      aggregate_failures do
        expect(result[:service]).to eq('ocr')
        expect(result[:requested_state]).to eq('degraded')
        expect(result.dig(:snapshot, :state)).to eq('degraded')
        expect(ExternalServiceStatus.degraded?(:ocr)).to eq(true)
      end
    end

    it 'serviceをdown状態に切り替える' do
      result = described_class.call(service: 'ai', state: 'down')

      aggregate_failures do
        expect(result[:service]).to eq('ai')
        expect(result[:requested_state]).to eq('down')
        expect(result.dig(:snapshot, :state)).to eq('down')
        expect(result.dig(:snapshot, :monitoring)).to eq(true)
        expect(ExternalServiceStatus.down?(:ai)).to eq(true)
      end
    end

    it 'resetでserviceを初期状態に戻す' do
      described_class.call(service: 'ocr', state: 'down')

      result = described_class.call(service: 'ocr', state: 'reset')

      aggregate_failures do
        expect(result[:requested_state]).to eq('reset')
        expect(result.dig(:snapshot, :state)).to eq('ok')
        expect(result.dig(:snapshot, :monitoring)).to eq(false)
        expect(ExternalServiceStatus.ok?(:ocr)).to eq(true)
      end
    end

    it '不正serviceを弾く' do
      expect { described_class.call(service: 'storage', state: 'down') }
        .to raise_error(ArgumentError, 'Unsupported service: storage')
    end

    it '不正stateを弾く' do
      expect { described_class.call(service: 'ocr', state: 'offline') }
        .to raise_error(ArgumentError, 'Unsupported state: offline')
    end

    it 'production相当では実行できない' do
      allow(described_class).to receive(:available?).and_return(false)

      expect { described_class.call(service: 'ocr', state: 'down') }
        .to raise_error(described_class::NotAvailableError)
    end
  end
end
