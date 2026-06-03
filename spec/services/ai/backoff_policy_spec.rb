require 'rails_helper'

RSpec.describe Ai::BackoffPolicy do
  subject(:policy) do
    described_class.new(
      base_delay: 1.0,
      max_delay: 10.0,
      jitter: -> { 0.25 }
    )
  end

  describe '#delay_for' do
    it 'Retry-Afterがあれば優先する' do
      expect(policy.delay_for(attempt: 1, retry_after: 3.0)).to eq(3.0)
    end

    it 'Retry-Afterが上限を超える場合はcapする' do
      expect(policy.delay_for(attempt: 1, retry_after: 30.0)).to eq(10.0)
    end

    it 'Retry-Afterがなければexponential backoffとjitterを使う' do
      aggregate_failures do
        expect(policy.delay_for(attempt: 1)).to eq(1.25)
        expect(policy.delay_for(attempt: 3)).to eq(4.25)
      end
    end
  end

  describe '#parse_retry_after' do
    it '秒数文字列をparseしてcapする' do
      expect(policy.parse_retry_after('30')).to eq(10.0)
    end

    it 'HTTP dateを秒数へ変換する' do
      now = Time.utc(2026, 6, 4, 12, 0, 0)
      value = (now + 4.seconds).httpdate

      expect(policy.parse_retry_after(value, now: now)).to eq(4.0)
    end

    it '不正値はnilにする' do
      expect(policy.parse_retry_after('not-a-date')).to be_nil
    end
  end
end
