require 'rails_helper'

RSpec.describe 'Receipt notification and quarantine concurrency' do
  self.use_transactional_tests = false

  def queue_pop(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def start_worker(pid_queue, &operation)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        pid_queue << connection.select_value('SELECT pg_backend_pid()')
        operation.call
      end
    rescue StandardError => error
      @errors << error
    end
  end

  def wait_for_database_lock(pid)
    Timeout.timeout(5) do
      loop do
        blocked = ActiveRecord::Base.connection.select_value(
          "SELECT cardinality(pg_blocking_pids(#{Integer(pid)})) > 0"
        )
        return if blocked

        Thread.pass
      end
    end
  end

  def finish_workers(release, *threads)
    release << true
    Timeout.timeout(5) { threads.each(&:join) }
    raise queue_pop(@errors) unless @errors.empty?
  ensure
    threads.each { |thread| thread.kill if thread&.alive? }
  end

  before do
    @receipt = create(:receipt, :completed)
    @user = @receipt.user
    @admin = create(:user, :admin)
    @errors = Queue.new
  end

  after do
    Receipt.where(id: @receipt&.id).destroy_all
    AuditLog.where(actor_user_id: @admin&.id).delete_all
    User.where(id: [ @user&.id, @admin&.id ]).destroy_all
  end

  it '通知削除後のsurface enqueueが失敗しても隔離と成功監査を失敗扱いにしない' do
    create(:notification, user: @user, notifiable: @receipt)
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_later_to).and_call_original
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_later_to)
      .with([ @user, :notifications ], any_args).and_raise(StandardError, 'private queue endpoint')
    allow(Rails.logger).to receive(:warn)
    request = instance_double(ActionDispatch::Request, request_id: 'quarantine-notification', remote_ip: '127.0.0.1', user_agent: 'Notification Spec')
    reauthentication = {
      method: 'passkey',
      reauthenticated_at: Time.current,
      user_id: @admin.id,
      session_version: @admin.session_version,
      expires_at: Time.current + Admin.passkey_reauth_window_duration
    }

    result = SystemOperations.execute_receipt_moderation_operation(
      operation: 'quarantine',
      receipt: @receipt,
      actor: @admin,
      reason: 'policy violation',
      request:,
      reauthentication:,
      confirmation: 'QUARANTINE RECEIPT'
    )

    aggregate_failures do
      expect(result).to be_success
      expect(@receipt.reload).to be_quarantined
      expect(@receipt.notifications).to be_empty
      expect(AuditLog.where(actor_user_id: @admin.id).pluck(:outcome)).to eq([ 'succeeded' ])
      expect(Rails.logger).to have_received(:warn).with('[Notification] broadcast_failed error_class=StandardError').once
    end
  end

  it '通知writerが先にReceipt lockを取った場合、後続quarantineが通知を同時に削除する' do
    writer_pid = Queue.new
    quarantine_pid = Queue.new
    writer_locked = Queue.new
    release_writer = Queue.new
    quarantined = Queue.new
    stale_receipt = Receipt.find(@receipt.id)

    writer = start_worker(writer_pid) do
      Receipt.transaction do
        Receipt.lock.find(@receipt.id)
        writer_locked << true
        queue_pop(release_writer)
        stale_receipt.send(:create_status_notification)
      end
    end
    queue_pop(writer_pid)
    queue_pop(writer_locked)
    quarantine = start_worker(quarantine_pid) do
      Receipt.find(@receipt.id).quarantine!(actor: @admin, reason: 'policy violation')
      quarantined << true
    end

    begin
      wait_for_database_lock(queue_pop(quarantine_pid))
      expect(quarantined).to be_empty
    ensure
      finish_workers(release_writer, writer, quarantine)
    end

    expect(@receipt.reload).to be_quarantined
    expect(@receipt.notifications).to be_empty
  end

  it 'quarantineが先にReceipt lockを取った場合、遅い通知writerはcommit後の隔離を見て作成しない' do
    quarantine_pid = Queue.new
    writer_pid = Queue.new
    quarantine_locked = Queue.new
    release_quarantine = Queue.new
    written = Queue.new
    stale_receipt = Receipt.find(@receipt.id)

    quarantine = start_worker(quarantine_pid) do
      Receipt.transaction do
        Receipt.find(@receipt.id).quarantine!(actor: @admin, reason: 'policy violation')
        quarantine_locked << true
        queue_pop(release_quarantine)
      end
    end
    queue_pop(quarantine_pid)
    queue_pop(quarantine_locked)
    writer = start_worker(writer_pid) do
      stale_receipt.send(:create_status_notification)
      written << true
    end

    begin
      wait_for_database_lock(queue_pop(writer_pid))
      expect(written).to be_empty
    ensure
      finish_workers(release_quarantine, quarantine, writer)
    end

    expect(@receipt.reload).to be_quarantined
    expect(@receipt.notifications).to be_empty
  end
end
