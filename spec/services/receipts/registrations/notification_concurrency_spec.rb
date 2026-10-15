require 'rails_helper'

RSpec.describe 'Receipt registration notification concurrency' do
  self.use_transactional_tests = false

  def report_concurrently(operation)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    errors = Queue.new
    workers = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          Timeout.timeout(5) { release.pop }
          results << Receipts::Registrations.report_failure(operation: operation, reason: 'storage_failed')
        end
      rescue StandardError => error
        errors << error
        ready << false
      end
    end

    begin
      expect(2.times.map { Timeout.timeout(5) { ready.pop } }).to eq([ true, true ])
      2.times { release << true }
      Timeout.timeout(5) { workers.each(&:join) }
    ensure
      workers.each { |worker| worker.kill if worker.alive? }
      workers.each(&:join)
    end
    raise errors.pop unless errors.empty?

    2.times.map { results.pop }
  end

  before do
    @user = create(:user)
  end

  after do
    @user.destroy!
  end

  it '同じ失敗操作の同時報告を通常通知1件へ揃える' do
    token = Receipts::Registrations.issue_token(user: @user, kind: 'upload')
    handle = nil
    Receipts::Registrations.with_operation(user: @user, token: token, kind: 'upload', input: []) do |operation|
      handle = operation
      false
    end
    replies = report_concurrently(handle)

    aggregate_failures do
      expect(replies).to eq([ true, true ])
      expect(@user.notifications.count).to eq(1)
      expect(@user.receipt_registration_operations.count).to eq(1)
      expect(@user.receipt_registration_operations.sole.notification_reported).to be(true)
      expect(@user.receipts).to be_empty
      expect(UsageCounter.where(user: @user)).to be_empty
    end
  end
end
