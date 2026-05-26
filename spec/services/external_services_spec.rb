require 'rails_helper'

RSpec.describe ExternalServices do
  describe '.status_snapshot' do
    it 'StatusSnapshotへ委譲する' do
      payload = { upload: { allowed: true } }

      allow(ExternalServices::StatusSnapshot).to receive(:call)
        .with(renderer: :renderer)
        .and_return(payload)

      expect(described_class.status_snapshot(renderer: :renderer)).to eq(payload)
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
      allow(Ocr::AvailabilityChecker).to receive(:call).and_return(true)

      expect(described_class.check_available?(:ocr)).to eq(true)
      expect(Ocr::AvailabilityChecker).to have_received(:call)
    end

    it 'AI checkerを呼ぶ' do
      allow(Ai::AvailabilityChecker).to receive(:call).and_return(true)

      expect(described_class.check_available?('ai')).to eq(true)
      expect(Ai::AvailabilityChecker).to have_received(:call)
    end

    it '未知serviceを明示的に弾く' do
      expect { described_class.check_available?(:storage) }
        .to raise_error(ArgumentError, 'Unsupported service: storage')
    end
  end
end
