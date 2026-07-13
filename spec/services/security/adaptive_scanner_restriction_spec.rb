# frozen_string_literal: true

require "rails_helper"

RSpec.describe Security::AdaptiveScannerRestriction do
  include ActiveSupport::Testing::TimeHelpers

  let(:ip_address) { "8.8.8.8" }

  around do |example|
    original_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    travel_to(Time.zone.parse("2026-07-13 12:00:00")) { example.run }
  ensure
    Rack::Attack.cache.store = original_store
  end

  it "3回目の高確度scanner probeから30分のIP全体制限を開始する" do
    first = record_probe
    travel 2.seconds
    second = record_probe
    travel 2.seconds
    third = record_probe

    aggregate_failures do
      expect(first).to include(active: false, strike_count: 1)
      expect(second).to include(active: false, strike_count: 2)
      expect(third).to include(active: true, tier: 1, duration_seconds: 30.minutes.to_i)
      expect(third.fetch(:expires_at)).to be_within(1.second).of(30.minutes.from_now)
      expect(described_class.active?(ip_address: ip_address)).to be(true)
    end
  end

  it "制限解除後もprobeが続く場合は6時間から最大30日まで段階的に延長する" do
    snapshots = []
    3.times do
      snapshots << record_probe
      travel 2.seconds
    end

    [ 6.hours, 24.hours, 7.days, 30.days, 30.days ].each do |expected_duration|
      current = snapshots.last
      travel current.fetch(:duration_seconds).seconds + 1.second
      snapshots << record_probe
      expect(snapshots.last.fetch(:duration_seconds)).to eq(expected_duration.to_i)
    end

    expect(snapshots.last.fetch(:tier)).to eq(5)
  end

  it "active制限中のprobeではstrikeや期限を延長しない" do
    3.times do
      record_probe
      travel 2.seconds
    end
    active = described_class.snapshot(ip_address: ip_address)

    10.times { record_probe }

    expect(described_class.snapshot(ip_address: ip_address)).to eq(active)
  end

  it "最初のstrikeから90日で履歴windowを閉じ、後続probeで無期限延長しない" do
    2.times do
      record_probe
      travel 2.seconds
    end

    travel 91.days
    snapshot = record_probe

    expect(snapshot).to include(active: false, strike_count: 1, tier: 0)
  end

  it "同じdedup window内のburstを1件として数え、複数tierを進めない" do
    ready = Queue.new
    start = Queue.new
    threads = Array.new(8) do
      Thread.new do
        ready << true
        start.pop
        described_class.record_probe(ip_address: ip_address)
      end
    end
    8.times { ready.pop }
    8.times { start << true }
    results = threads.map(&:value)

    aggregate_failures do
      expect(results.count { |result| result.fetch(:strike_count) == 1 }).to eq(1)
      expect(results).to all(include(active: false, tier: 0))
      expect(described_class.active?(ip_address: ip_address)).to be(false)
    end
  end

  it "private・loopback・reserved addressはprobe自体を記録してもIP全体制限しない" do
    %w[127.0.0.1 10.0.0.1 203.0.113.10 ::1].each do |address|
      3.times do
        described_class.record_probe(ip_address: address)
        travel 2.seconds
      end

      expect(described_class.active?(ip_address: address)).to be(false), address
    end
  end

  it "cache keyへraw IPを含めず、resetでactive・strike・dedup履歴を完全に消す" do
    3.times do
      record_probe
      travel 2.seconds
    end
    store = Rack::Attack.cache.store
    keys_before_reset = store.instance_variable_get(:@data).keys

    described_class.reset!(ip_address: ip_address)

    aggregate_failures do
      expect(keys_before_reset).not_to be_empty
      expect(keys_before_reset.join(" ")).not_to include(ip_address)
      expect(store.instance_variable_get(:@data).keys).to be_empty
      expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, strike_count: 0)
      expect(record_probe).to include(active: false, strike_count: 1)
    end
  end

  it "cache障害時はscanner pathの呼出側を失敗させず通常requestをfail openにする" do
    broken_store = instance_double(ActiveSupport::Cache::Store)
    allow(broken_store).to receive(:read).and_raise(ActiveRecord::ConnectionNotEstablished)
    allow(broken_store).to receive(:write).and_raise(ActiveRecord::ConnectionNotEstablished)
    allow(Rack::Attack.cache).to receive(:store).and_return(broken_store)

    aggregate_failures do
      expect(described_class.record_probe(ip_address: ip_address)).to include(active: false)
      expect(described_class.active?(ip_address: ip_address)).to be(false)
    end
  end

  it "active payloadの書込みがfalseまたはnilなら制限成功とせずstrikeを巻き戻す" do
    [ false, nil ].each do |write_result|
      store = ActiveSupport::Cache::MemoryStore.new
      reject_active_write = true
      allow(store).to receive(:write).and_wrap_original do |original, *args, **kwargs|
        if reject_active_write && args.first.to_s.include?(":active:")
          write_result
        else
          original.call(*args, **kwargs)
        end
      end
      Rack::Attack.cache.store = store

      2.times do
        record_probe
        travel 2.seconds
      end
      rejected = record_probe

      aggregate_failures "write_result=#{write_result.inspect}" do
        expect(rejected).to include(active: false, tier: 0, strike_count: 2)
        expect(described_class.active?(ip_address: ip_address)).to be(false)
      end

      reject_active_write = false
      travel 2.seconds
      activated = record_probe

      aggregate_failures "retry write_result=#{write_result.inspect}" do
        expect(activated).to include(active: true, tier: 1, strike_count: 3)
        expect(activated.fetch(:duration_seconds)).to eq(30.minutes.to_i)
      end
    end
  end

  it "active write失敗後のstrike rollbackも失敗した場合に次回tierを飛ばさない" do
    store = ActiveSupport::Cache::MemoryStore.new
    reject_active_write = true
    allow(store).to receive(:write).and_wrap_original do |original, *args, **kwargs|
      if reject_active_write && args.first.to_s.include?(":active:")
        false
      else
        original.call(*args, **kwargs)
      end
    end
    allow(store).to receive(:decrement).and_return(nil)
    allow(store).to receive(:delete).and_wrap_original do |original, *args, **kwargs|
      if args.first.to_s.include?(":strikes:")
        false
      else
        original.call(*args, **kwargs)
      end
    end
    Rack::Attack.cache.store = store

    2.times do
      record_probe
      travel 2.seconds
    end
    rejected = record_probe
    reject_active_write = false
    travel 2.seconds
    activated = record_probe

    aggregate_failures do
      expect(rejected).to include(active: false, tier: 0)
      expect(activated).to include(active: true, tier: 1, strike_count: 4)
      expect(activated.fetch(:duration_seconds)).to eq(30.minutes.to_i)
    end
  end

  it "reset後にadaptive keyが残る場合は失敗を返す" do
    3.times do
      record_probe
      travel 2.seconds
    end
    store = Rack::Attack.cache.store
    allow(store).to receive(:delete_multi).and_return(0)

    result = described_class.reset!(ip_address: ip_address)

    aggregate_failures do
      expect(result).to be(false)
      expect(described_class.active?(ip_address: ip_address)).to be(true)
    end
  end

  it "reset確認用cache writeが失敗する場合は解除成功としない" do
    3.times do
      record_probe
      travel 2.seconds
    end
    store = Rack::Attack.cache.store
    allow(store).to receive(:write).and_wrap_original do |original, *args, **kwargs|
      if args.first.to_s.include?(":reset_verification:")
        false
      else
        original.call(*args, **kwargs)
      end
    end

    expect(described_class.reset!(ip_address: ip_address)).to be(false)
  end

  def record_probe
    described_class.record_probe(ip_address: ip_address)
  end
end
