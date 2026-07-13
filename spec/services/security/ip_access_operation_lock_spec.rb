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
    ip_address = "8.8.8.8'); SELECT pg_sleep(1); --"
    unsigned_lock_id = Zlib.crc32("recify.security_ip_access.#{ip_address}")
    expected_lock_id = unsigned_lock_id >= (2**31) ? unsigned_lock_id - (2**32) : unsigned_lock_id
    allow(SecurityIpBlock).to receive(:connection).and_return(connection)
    expect(connection).to receive(:exec_query)
      .with(
        'SELECT pg_advisory_xact_lock($1, $2) IS NULL AS lock_result_ignored',
        'Security::IpAccessOperationLock',
        satisfy do |binds|
          binds.map(&:value_for_database) == [
            described_class::ADVISORY_LOCK_NAMESPACE,
            expected_lock_id
          ]
        end,
        prepare: true
      )
      .and_call_original

    described_class.call(ip_address: ip_address) { true }
  end
end
