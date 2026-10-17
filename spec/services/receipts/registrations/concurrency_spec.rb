require 'rails_helper'

RSpec.describe 'Receipt registration concurrency' do
  self.use_transactional_tests = false

  before do
    @user = create(:user)
  end

  after do
    ReceiptRegistrationOperation.where(user_id: @user.id).delete_all
    @user.destroy!
  end

  def queue_pop(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def registration_tokens_with_distinct_locks(input:)
    # Choose concurrent operations without depending on the file lock bucket implementation.
    first_token = Receipts::Registrations.issue_token(user: @user, kind: 'manual')
    tokens = [ first_token ]
    Receipts::Registrations.with_operation(user: @user, token: first_token, kind: 'manual', input: input) do
      8.times do
        token = Receipts::Registrations.issue_token(user: @user, kind: 'manual')
        probe = Receipts::Registrations.with_operation(user: @user, token: token, kind: 'manual', input: input) { false }
        next if probe.state == 'processing'

        expect(probe.state).to eq('failed')
        tokens << token
        break
      end
      false
    end
    raise 'independent registration locks unavailable' unless tokens.size == 2

    tokens
  end

  it '同じ操作の並行送信を最大1回の受付と利用回数へ揃える' do
    token = Receipts::Registrations.issue_token(user: @user, kind: 'manual')
    entered = Queue.new
    release = Queue.new
    completed = Queue.new
    errors = Queue.new

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        result = Receipts::Registrations.with_operation(user: @user, token: token, kind: 'manual', input: {}) do |operation|
          entered << true
          queue_pop(release)
          Receipt.transaction do
            User.lock.find(@user.id)
            receipt = create(:receipt, user: @user)
            Usage.consume_manual_receipt!(user: @user)
            Receipts::Registrations.accept!(operation: operation, receipts: [ receipt ])
          end
          true
        end
        completed << result
      end
    rescue StandardError => error
      errors << error
      entered << false
    end

    begin
      expect(queue_pop(entered)).to be(true)
      competing = Receipts::Registrations.with_operation(user: @user, token: token, kind: 'manual', input: {}) do
        raise 'concurrent request must not execute'
      end
      expect(competing.state).to eq('processing')
    ensure
      release << true
      Timeout.timeout(5) { writer.join }
    end
    raise queue_pop(errors) unless errors.empty?

    replay = Receipts::Registrations.with_operation(user: @user, token: token, kind: 'manual', input: {}) do
      raise 'completed request must not execute again'
    end
    aggregate_failures do
      expect(queue_pop(completed)).to be_accepted
      expect(replay).to be_replayed
      expect(@user.receipts.count).to eq(1)
      expect(UsageCounter.find_by!(user: @user, key: 'manual_receipts_per_day').used_count).to eq(1)
    end
  end

  it 'domain transaction外からの受付確定を拒否する' do
    token = Receipts::Registrations.issue_token(user: @user, kind: 'manual')
    receipt = create(:receipt, user: @user)

    result = Receipts::Registrations.with_operation(user: @user, token: token, kind: 'manual', input: {}) do |operation|
      expect do
        Receipts::Registrations.accept!(operation: operation, receipts: [ receipt ])
      end.to raise_error(Receipts::Registrations::InvalidOperation)
      false
    end

    expect(result.state).to eq('failed')
  end

  it '異なる受付IDで残り手動登録枠1を競合してもReceipt・利用回数・受付確定は1件だけにする' do
    create(:user_limit_override, user: @user, key: 'manual_receipts_per_day', value: { 'value' => 1 })
    attributes = {
      'store_name' => '登録競合検証店',
      'total_amount' => 100,
      'payment_method' => 'cash',
      'review_reasons' => [],
      'receipt_items_attributes' => {
        '0' => { 'confirmed_name' => '検証品', 'price' => 100, 'quantity' => 1, 'line_total' => 100 }
      }
    }
    tokens = registration_tokens_with_distinct_locks(input: attributes)
    entered = Queue.new
    release = Queue.new
    completed = Queue.new
    errors = Queue.new
    writers = tokens.map do |token|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          user = User.find(@user.id)
          result = Receipts::Registrations.with_operation(user: user, token: token, kind: 'manual', input: attributes) do |operation|
            entered << true
            queue_pop(release)
            Receipts::Editing.create_manual(
              receipt: user.receipts.new,
              attributes: attributes.deep_dup,
              user: user,
              items_missing: false,
              operation: operation
            )
          end
          completed << result
        end
      rescue Usage::LimitExceeded => error
        completed << error
      rescue StandardError => error
        errors << error
        entered << false
      end
    end

    begin
      expect(2.times.map { queue_pop(entered) }).to eq([ true, true ])
    ensure
      2.times { release << true }
      begin
        Timeout.timeout(5) { writers.each(&:join) }
      ensure
        writers.each { |writer| writer.kill if writer.alive? }
        writers.each(&:join)
      end
    end
    raise queue_pop(errors) unless errors.empty?

    outcomes = 2.times.map { queue_pop(completed) }
    accepted = outcomes.grep(Receipts::Registrations::Result)
    rejected = outcomes.grep(Usage::LimitExceeded)
    operations = ReceiptRegistrationOperation.where(user_id: @user.id)
    aggregate_failures do
      expect(accepted.size).to eq(1)
      expect(accepted.first).to be_accepted
      expect(accepted.first.value).to be_saved
      expect(rejected.size).to eq(1)
      expect(rejected.first.key).to eq('manual_receipts_per_day')
      expect(operations.pluck(:state)).to contain_exactly('accepted', 'failed')
      expect(@user.receipts.count).to eq(1)
      expect(operations.find_by!(state: 'accepted').receipt_ids).to eq(@user.receipts.pluck(:id))
      expect(operations.find_by!(state: 'failed').receipt_ids).to eq([])
      expect(UsageCounter.find_by!(user: @user, key: 'manual_receipts_per_day').used_count).to eq(1)
    end
  end
end
