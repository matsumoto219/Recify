require "rails_helper"

RSpec.describe Storage::QuotaReservation do
  let(:user) { create(:user) }

  before do
    allow(Storage::GlobalQuota).to receive(:can_add?).and_return(true)
    allow_any_instance_of(Storage::UsageCalculator).to receive(:can_add?).and_return(true)
  end

  it "global quotaをlock取得後に再判定し、超過時は処理を実行しない" do
    allow(Storage::GlobalQuota).to receive(:can_add?).and_return(false)
    executed = false

    expect do
      described_class.call(byte_size: 1.kilobyte) { executed = true }
    end.to raise_error(Storage::QuotaExceeded) { |error| expect(error.scope).to eq(:global) }

    expect(executed).to be(false)
  end

  it "user rowをlockした後にuser quotaを再判定する" do
    allow_any_instance_of(Storage::UsageCalculator).to receive(:can_add?).and_return(false)
    executed = false

    expect do
      described_class.call(byte_size: 1.kilobyte, user: user) { executed = true }
    end.to raise_error(Storage::QuotaExceeded) { |error| expect(error.scope).to eq(:user) }

    expect(executed).to be(false)
  end

  it "差し替え対象blobをglobal/user両方の判定へ渡す" do
    blob = instance_double(ActiveStorage::Blob)

    expect(Storage::GlobalQuota).to receive(:can_add?).with(2.kilobytes, excluding_blob: blob).and_return(true)
    expect_any_instance_of(Storage::UsageCalculator)
      .to receive(:can_add?).with(2.kilobytes, excluding_blob: blob).and_return(true)

    expect(
      described_class.call(byte_size: 2.kilobytes, user: user, excluding_blob: blob) { :saved }
    ).to eq(:saved)
  end

  it "process内の同時判定と保存blockを直列化する" do
    first_entered = Queue.new
    release_first = Queue.new
    second_entered = Queue.new
    errors = Queue.new

    first = Thread.new do
      described_class.call(byte_size: 1) do
        first_entered << true
        release_first.pop
      end
    rescue StandardError => error
      errors << error
    end
    first_entered.pop

    second = Thread.new do
      described_class.call(byte_size: 1) { second_entered << true }
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

  it "全process共通のdatabase advisory transaction lockを取得する" do
    connection = ActiveStorage::Blob.connection
    allow(ActiveStorage::Blob).to receive(:connection).and_return(connection)
    expect(connection).to receive(:execute)
      .with(a_string_including("pg_advisory_xact_lock"))
      .and_call_original

    described_class.call(byte_size: 1) { true }
  end
end
