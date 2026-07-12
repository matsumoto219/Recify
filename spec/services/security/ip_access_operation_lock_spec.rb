require 'rails_helper'

RSpec.describe Security::IpAccessOperationLock do
  it '同じIPの操作をprocess内で直列化する' do
    first_entered = Queue.new
    release_first = Queue.new
    second_entered = Queue.new
    errors = Queue.new

    first = Thread.new do
      described_class.call(ip_address: '8.8.8.8') do
        first_entered << true
        release_first.pop
      end
    rescue StandardError => error
      errors << error
    end
    first_entered.pop

    second = Thread.new do
      described_class.call(ip_address: '8.8.8.8') { second_entered << true }
    rescue StandardError => error
      errors << error
    end

    begin
      expect do
        Timeout.timeout(0.05) { second_entered.pop }
      end.to raise_error(Timeout::Error)
    ensure
      release_first << true
      [ first, second ].each(&:join)
    end

    raise errors.pop unless errors.empty?

    expect(second_entered.pop).to eq(true)
  end

  it 'IPごとのdatabase advisory transaction lockを取得する' do
    connection = SecurityIpBlock.connection
    allow(SecurityIpBlock).to receive(:connection).and_return(connection)
    expect(connection).to receive(:execute)
      .with(a_string_including('pg_advisory_xact_lock'))
      .and_call_original

    described_class.call(ip_address: '8.8.8.8') { true }
  end
end
