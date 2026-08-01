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
      expect(durable_state_actions.last).to have_attributes(
        status: "active",
        expires_at: be_within(1.second).of(30.minutes.from_now)
      )
      expect(durable_state_actions.last.metadata).to include(
        "tier" => 1,
        "strike_count" => 3,
        "duration_seconds" => 30.minutes.to_i
      )
    end
  end

  it "active cacheがevictされても永続stateから残り期間を復元する" do
    active = activate_tier_one
    delete_adaptive_cache(:active)

    recovered = described_class.snapshot(ip_address: ip_address)

    aggregate_failures do
      expect(recovered).to include(
        active: true,
        tier: 1,
        strike_count: 3,
        duration_seconds: 30.minutes.to_i
      )
      expect(recovered.fetch(:expires_at)).to be_within(1.second).of(active.fetch(:expires_at))
      expect(read_adaptive_cache(:active)).to include(
        tier: 1,
        strike_count: 3,
        expires_at_epoch: active.fetch(:expires_at).to_i
      )
    end
  end

  it "active cache hitでは永続stateを再照会しない" do
    activate_tier_one

    expect(SecurityIpAction).not_to receive(:where)

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: true, tier: 1)
  end

  it "永続stateがないIPはinactive cache hitで再照会しない" do
    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false)
    expect(SecurityIpAction).not_to receive(:where)

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false)
  end

  it "deploy前形式のactive cacheを継続しながら永続stateへ移行する" do
    expires_at = 30.minutes.from_now
    write_adaptive_cache(
      :active,
      {
        tier: 1,
        strike_count: 3,
        duration_seconds: 30.minutes.to_i,
        expires_at_epoch: expires_at.to_i
      },
      expires_in: 30.minutes
    )

    snapshot = described_class.snapshot(ip_address: ip_address)

    aggregate_failures do
      expect(snapshot).to include(active: true, tier: 1, strike_count: 3)
      expect(durable_state_actions.last).to have_attributes(status: "active")
      expect(read_adaptive_cache(:active)).to include(active: true, durable: true)
    end
  end

  it "deploy前のactive cacheが既にevictされていても既存actionから永続stateへ移行する" do
    legacy_action = create_legacy_scanner_action

    snapshot = described_class.snapshot(ip_address: ip_address)

    aggregate_failures do
      expect(snapshot).to include(active: true, tier: 1, strike_count: 3)
      expect(snapshot.fetch(:expires_at)).to be_within(1.second).of(legacy_action.expires_at)
      expect(durable_state_actions.last).to have_attributes(status: "active")
      expect(read_adaptive_cache(:active)).to include(
        tier: 1,
        strike_count: 3,
        expires_at_epoch: legacy_action.expires_at.to_i
      )
    end
  end

  it "deploy前のscanner resetより古いactive actionを復活させない" do
    legacy_action = create_legacy_scanner_action
    create(
      :security_ip_action,
      ip_address: ip_address,
      action_type: "rack_attack_ban_reset",
      source: "manual_admin",
      status: "reset",
      matched_rule: "rack_attack/reset",
      first_seen_at: legacy_action.last_seen_at + 1.minute,
      last_seen_at: legacy_action.last_seen_at + 1.minute,
      expires_at: legacy_action.last_seen_at + 1.minute,
      metadata: { reset_targets: [ "scanner" ] }
    )

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
    expect(durable_state_actions.last).to have_attributes(status: "revoked")
  end

  it "deploy前reset後に遅延記録されたactive actionも復活させない" do
    reset_action = create_legacy_scanner_reset
    create_legacy_scanner_action(
      first_seen_at: reset_action.last_seen_at + 1.minute,
      last_seen_at: reset_action.last_seen_at + 1.minute
    )

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
    expect(durable_state_actions.last).to have_attributes(status: "revoked")
  end

  it "scanner以外だけを対象にしたdeploy前resetは移行を妨げない" do
    create_legacy_scanner_action
    create_legacy_scanner_reset(reset_targets: [ "admin_probe" ], target: "admin_probe")

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: true, tier: 1)
    expect(durable_state_actions.last).to have_attributes(status: "active")
  end

  it "旧metadataのtargetだけに残るscanner resetもbarrierとして扱う" do
    create_legacy_scanner_action
    create_legacy_scanner_reset(reset_targets: [], target: "all")

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
    expect(durable_state_actions.last).to have_attributes(status: "revoked")
  end

  it "後続hitだけを表すadaptive rule actionはdeploy前activation根拠にしない" do
    create_legacy_scanner_action(matched_rule: "adaptive/scanner_restrictions")

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
    expect(durable_state_actions).not_to exist
  end

  it "不整合なdeploy前action metadataをactive stateへ昇格しない" do
    action = create_legacy_scanner_action
    action.update!(metadata: action.metadata.merge("duration_seconds" => 1))

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
    expect(durable_state_actions).not_to exist
  end

  it "revoked stateより古いdeploy前形式cacheをactiveへ戻さない" do
    active = activate_tier_one
    expect(described_class.reset!(ip_address: ip_address)).to be(true)
    write_adaptive_cache(
      :active,
      {
        tier: 1,
        strike_count: 3,
        duration_seconds: 30.minutes.to_i,
        expires_at_epoch: active.fetch(:expires_at).to_i
      },
      expires_in: 30.minutes
    )

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
  end

  it "期限切れ専用stateとdeploy前cacheの競合後もstrike進行を維持する" do
    active = activate_tier_one
    travel active.fetch(:duration_seconds).seconds + 1.second
    write_adaptive_cache(
      :active,
      {
        tier: 1,
        strike_count: 3,
        duration_seconds: 30.minutes.to_i,
        expires_at_epoch: 30.minutes.from_now.to_i
      },
      expires_in: 30.minutes
    )

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false)
    expect(read_adaptive_cache(:active)).to include(
      active: false,
      durable_progress: true,
      tier: 1,
      strike_count: 3
    )
    %i[strikes tier].each { |kind| delete_adaptive_cache(kind) }

    expect(record_probe).to include(active: true, tier: 2, strike_count: 4)
  end

  it "deploy前cache移行のtransaction commit失敗時にdurable印だけを残さない" do
    expires_at = 30.minutes.from_now
    write_adaptive_cache(
      :active,
      {
        tier: 1,
        strike_count: 3,
        duration_seconds: 30.minutes.to_i,
        expires_at_epoch: expires_at.to_i
      },
      expires_in: 30.minutes
    )
    allow(SecurityIpBlock).to receive(:transaction).and_wrap_original do |original, *args, **kwargs, &block|
      original.call(*args, **kwargs) do
        block.call
        raise ActiveRecord::Rollback
      end
      raise ActiveRecord::StatementInvalid, "synthetic commit failure"
    end

    snapshot = described_class.snapshot(ip_address: ip_address)

    aggregate_failures do
      expect(snapshot).to include(active: true, tier: 1)
      expect(durable_state_actions).not_to exist
      expect(read_adaptive_cache(:active)).to include(tier: 1)
      expect(read_adaptive_cache(:active)).not_to include(durable: true)
    end
  end

  it "永続stateの期限後はcacheへactiveを復元しない" do
    active = activate_tier_one
    delete_adaptive_cache(:active)
    travel_to(active.fetch(:expires_at) + 1.second)

    snapshot = described_class.snapshot(ip_address: ip_address)

    aggregate_failures do
      expect(snapshot).to include(active: false, tier: 0)
      expect(read_adaptive_cache(:active)).to include(active: false)
    end
  end

  it "cache履歴を失っても同じstrike windowの段階を永続stateから継続する" do
    current = activate_tier_one
    4.times do
      travel current.fetch(:duration_seconds).seconds + 1.second
      current = record_probe
    end
    expect(current).to include(active: true, tier: 5, strike_count: 7)

    %i[active strikes tier].each { |kind| delete_adaptive_cache(kind) }
    travel current.fetch(:duration_seconds).seconds + 1.second

    tier_six = record_probe

    expect(tier_six).to include(
      active: true,
      tier: 6,
      strike_count: 8,
      duration_seconds: 90.days.to_i
    )
  end

  it "inactive cacheだけ残って進行cacheがevictされても同じstrike windowを継続する" do
    tier_one = activate_tier_one
    travel tier_one.fetch(:duration_seconds).seconds + 1.second
    tier_two = record_probe
    expect(tier_two).to include(active: true, tier: 2, strike_count: 4)

    travel tier_two.fetch(:duration_seconds).seconds + 1.second
    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false)
    expect(read_adaptive_cache(:active)).to include(
      active: false,
      durable_progress: true,
      tier: 2,
      strike_count: 4
    )
    %i[strikes tier].each { |kind| delete_adaptive_cache(kind) }

    expect(record_probe).to include(active: true, tier: 3, strike_count: 5)
  end

  it "inactive cache hitの通常pathではDB lockや進行cache writeを行わない" do
    tier_one = activate_tier_one
    travel tier_one.fetch(:duration_seconds).seconds + 1.second
    tier_two = record_probe
    travel tier_two.fetch(:duration_seconds).seconds + 1.second
    described_class.snapshot(ip_address: ip_address)
    %i[strikes tier].each { |kind| delete_adaptive_cache(kind) }
    expect(Security::IpAccessOperationLock).not_to receive(:call)

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false)

    aggregate_failures do
      expect(read_adaptive_cache(:strikes)).to be_nil
      expect(read_adaptive_cache(:tier)).to be_nil
    end
  end

  it "制限解除後もprobeが続く場合は6時間から最大90日まで段階的に延長する" do
    snapshots = []
    3.times do
      snapshots << record_probe
      travel 2.seconds
    end

    [ 6.hours, 24.hours, 7.days, 30.days, 90.days ].each do |expected_duration|
      current = snapshots.last
      travel current.fetch(:duration_seconds).seconds + 1.second
      snapshots << record_probe
      expect(snapshots.last.fetch(:duration_seconds)).to eq(expected_duration.to_i)
    end

    tier_six = snapshots.last
    travel 1.day
    during_tier_six = record_probe

    aggregate_failures do
      expect(described_class::DURATIONS).to eq(
        [ 30.minutes, 6.hours, 24.hours, 7.days, 30.days, 90.days ]
      )
      expect(tier_six).to include(active: true, tier: 6, duration_seconds: 90.days.to_i)
      expect(during_tier_six).to include(active: true, tier: 6, duration_seconds: 90.days.to_i)
      expect(during_tier_six.fetch(:expires_at)).to eq(tier_six.fetch(:expires_at))
    end

    travel_to(tier_six.fetch(:expires_at) + 1.second)
    first = record_probe
    travel 2.seconds
    second = record_probe
    travel 2.seconds
    third = record_probe

    aggregate_failures do
      expect(first).to include(active: false, tier: 0, strike_count: 1)
      expect(second).to include(active: false, tier: 0, strike_count: 2)
      expect(third).to include(active: true, tier: 1, strike_count: 3)
    end
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

  it "新しい90日strike windowでは残存tier履歴を引き継がずtier 1から再開する" do
    window_started_at = Time.current
    current = nil
    3.times do
      current = record_probe
      travel 2.seconds
    end
    4.times do
      travel current.fetch(:duration_seconds).seconds + 1.second
      current = record_probe
    end
    expect(current).to include(active: true, tier: 5)

    travel_to(window_started_at + 91.days)
    write_adaptive_cache(:tier, 5, expires_in: 90.days)
    expect(read_adaptive_cache(:tier)).to eq(5)
    first = record_probe
    travel 2.seconds
    second = record_probe
    travel 2.seconds
    third = record_probe

    aggregate_failures do
      expect(first).to include(active: false, strike_count: 1, tier: 0)
      expect(second).to include(active: false, strike_count: 2, tier: 0)
      expect(third).to include(
        active: true,
        strike_count: 3,
        tier: 1,
        duration_seconds: 30.minutes.to_i
      )
    end
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

  it "並行activation待機後にactive stateを再確認してtierを即時延長しない" do
    ready = Queue.new
    start = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ready << true
        start.pop
        adaptive_restriction.send(:activate, 3)
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)

    aggregate_failures do
      expect(results).to all(include(active: true, tier: 1, duration_seconds: 30.minutes.to_i))
      expect(durable_state_actions.where(status: "active").count).to eq(1)
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

  it "cache keyへraw IPを含めず、resetで永続stateをrevokedにして進行履歴を消す" do
    activate_tier_one
    store = Rack::Attack.cache.store
    keys_before_reset = store.instance_variable_get(:@data).keys

    result = described_class.reset!(ip_address: ip_address)
    delete_adaptive_cache(:active)

    aggregate_failures do
      expect(result).to be(true)
      expect(keys_before_reset).not_to be_empty
      expect(keys_before_reset.join(" ")).not_to include(ip_address)
      expect(durable_state_actions.last).to have_attributes(status: "revoked")
      expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, strike_count: 0)
      expect(record_probe).to include(active: false, strike_count: 1)
    end
  end

  it "reset中のinactive sentinelをcache missとして永続activeへ戻さない" do
    activate_tier_one
    verification_token = "reset-verification-token"
    write_adaptive_cache(
      :active,
      { active: false, verification_token: verification_token },
      expires_in: described_class::RESET_VERIFICATION_TTL
    )

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false)
  end

  it "専用stateはapp clock差ではなくserializeされたinsert順で判定する" do
    activate_tier_one
    active_state = durable_state_actions.last
    expect(described_class.reset!(ip_address: ip_address)).to be(true)
    revoked_state = durable_state_actions.last
    active_state.update_columns(last_seen_at: 1.day.from_now)
    revoked_state.update_columns(last_seen_at: 1.day.ago)
    delete_adaptive_cache(:active)

    expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
  end

  it "reset tombstoneを旧activeとstrike windowより長く保持してcleanup後も復活させない" do
    now = Time.current
    active_state = create(
      :security_ip_action,
      ip_address: ip_address,
      action_type: "scanner_restriction",
      source: "rack_attack",
      status: "active",
      matched_rule: described_class::DURABLE_STATE_MATCHED_RULE,
      first_seen_at: now,
      last_seen_at: now,
      expires_at: 90.days.from_now,
      metadata: {
        active: true,
        tier: 6,
        strike_count: 8,
        duration_seconds: 90.days.to_i,
        strike_expires_at_epoch: 90.days.from_now.to_i
      }
    )
    expect(described_class.reset!(ip_address: ip_address)).to be(true)
    revoked_state = durable_state_actions.last
    create(
      :system_setting,
      key: "retention.security_events_medium_days",
      value: SystemSettings.stored_value(30)
    )

    aggregate_failures do
      expect(revoked_state).to have_attributes(status: "revoked")
      expect(revoked_state.expires_at).to be >= active_state.expires_at
      expect(revoked_state.expires_at).to be_within(1.second).of(90.days.from_now)
    end

    travel 31.days
    SecurityEvents::RetentionCleanup.call(dry_run: false, now: Time.current)
    delete_adaptive_cache(:active)

    aggregate_failures do
      expect(SecurityIpAction.where(id: [ active_state.id, revoked_state.id ]).count).to eq(2)
      expect(described_class.snapshot(ip_address: ip_address)).to include(active: false, tier: 0)
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
      durable_state_actions.delete_all
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
        expect(durable_state_actions.where(status: "active")).not_to exist
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
    delete_adaptive_cache(:active)
    expect(described_class.snapshot(ip_address: ip_address)).to include(active: true)
  end

  it "reset確認keyのcleanupは別resetのtokenを削除しない" do
    write_adaptive_cache(:reset_verification, "newer-reset-token")

    adaptive_restriction.send(
      :delete_reset_verification_key_if_token,
      "older-reset-token"
    )

    expect(read_adaptive_cache(:reset_verification)).to eq("newer-reset-token")
  end

  def record_probe
    described_class.record_probe(ip_address: ip_address)
  end

  def activate_tier_one
    current = nil
    3.times do
      current = record_probe
      travel 2.seconds
    end
    current
  end

  def durable_state_actions
    SecurityIpAction.where(
      ip_address: ip_address,
      action_type: "scanner_restriction",
      source: "rack_attack",
      matched_rule: described_class::DURABLE_STATE_MATCHED_RULE
    ).order(:id)
  end

  def create_legacy_scanner_action(
    matched_rule: "fail2ban/scanner_paths",
    first_seen_at: Time.current,
    last_seen_at: Time.current
  )
    create(
      :security_ip_action,
      ip_address: ip_address,
      action_type: "scanner_restriction",
      source: "rack_attack",
      status: "active",
      matched_rule: matched_rule,
      first_seen_at: first_seen_at,
      last_seen_at: last_seen_at,
      expires_at: 30.minutes.from_now,
      metadata: {
        active: true,
        tier: 1,
        strike_count: 3,
        duration_seconds: 30.minutes.to_i
      }
    )
  end

  def create_legacy_scanner_reset(
    reset_targets: [ "scanner" ],
    target: "scanner"
  )
    create(
      :security_ip_action,
      ip_address: ip_address,
      action_type: "rack_attack_ban_reset",
      source: "manual_admin",
      status: "reset",
      matched_rule: "rack_attack/reset",
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      expires_at: Time.current,
      metadata: {
        reset_targets: reset_targets,
        target: target
      }
    )
  end

  def adaptive_restriction
    described_class.new(ip_address: ip_address)
  end

  def adaptive_cache_key(kind)
    adaptive_restriction.send(:"#{kind.to_s.singularize}_key")
  end

  def delete_adaptive_cache(kind)
    Rack::Attack.cache.store.delete(adaptive_cache_key(kind))
  end

  def read_adaptive_cache(kind)
    Rack::Attack.cache.store.read(adaptive_cache_key(kind))
  end

  def write_adaptive_cache(kind, value, **options)
    Rack::Attack.cache.store.write(adaptive_cache_key(kind), value, **options)
  end
end
