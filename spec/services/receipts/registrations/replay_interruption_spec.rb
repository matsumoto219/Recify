require 'rails_helper'

RSpec.describe 'Receipt registration interrupted replay' do
  include ActiveSupport::Testing::TimeHelpers

  self.use_transactional_tests = false

  before do
    @user = create(:user)
    @token = Receipts::Registrations.issue_token(user: @user, kind: 'manual')
  end

  after do
    ReceiptRegistrationOperation.where(user_id: @user.id).delete_all
    @user.destroy!
  end

  def leave_interrupted_registration
    expect do
      Receipts::Registrations.with_operation(user: @user, token: @token, kind: 'manual', input: {}) do
        raise SystemExit, 'synthetic interrupted operation'
      end
    end.to raise_error(SystemExit, 'synthetic interrupted operation')
    ReceiptRegistrationOperation.find_by!(user_id: @user.id)
  end

  def accept_registration
    Receipts::Registrations.with_operation(user: @user, token: @token, kind: 'manual', input: {}) do |operation|
      Receipt.transaction do
        User.lock.find(@user.id)
        receipt = create(:receipt, user: @user)
        Usage.consume_manual_receipt!(user: @user)
        Receipts::Registrations.accept!(operation: operation, receipts: [ receipt ])
      end
    end
  end

  it '停止後に残ったprocessingを同じフォームから明示再送して一度だけ受付できる' do
    record = leave_interrupted_registration
    old_attempt = record.attempt_key
    expect(Receipts::Processing).not_to receive(:start)

    accepted = accept_registration

    aggregate_failures do
      expect(accepted).to be_accepted
      expect(record.reload.state).to eq('accepted')
      expect(record.attempt_key).not_to eq(old_attempt)
      expect(@user.receipts.count).to eq(1)
      expect(@user.notifications).to be_empty
      expect(UsageCounter.find_by!(user: @user, key: 'manual_receipts_per_day').used_count).to eq(1)
    end
  end

  it '共有bucketがbusyなら停止済みと断定せず処理中を返して再実行しない' do
    record = leave_interrupted_registration
    allow(Storage).to receive(:with_upload_operation_lock).with(
      key: "#{@user.id}:#{record.operation_key}"
    ).and_return(nil)

    result = accept_registration

    expect(result.state).to eq('processing')
    expect(record.reload.state).to eq('processing')
    expect(@user.receipts).to be_empty
    expect(@user.notifications).to be_empty
  end

  it 'lock取得前に別writerが受付を確定した場合は最新のacceptedを再送結果にする' do
    leave_interrupted_registration
    accepted = nil
    lock_checked = false
    allow(Storage).to receive(:with_upload_operation_lock).and_wrap_original do |method, **arguments, &operation|
      unless lock_checked
        lock_checked = true
        writer = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { accept_registration }
        end
        begin
          accepted = Timeout.timeout(5) { writer.value }
        ensure
          writer.kill if writer.alive?
          writer.join
        end
      end
      method.call(**arguments, &operation)
    end

    result = ActiveRecord::Base.cache { accept_registration }

    expect(result).to be_replayed
    expect(result.receipt_ids).to eq(accepted.receipt_ids)
    expect(@user.receipts.count).to eq(1)
  end

  it 'lockのI/O失敗を確定失敗に変換せず通知も作らない' do
    record = leave_interrupted_registration
    allow(Storage).to receive(:with_upload_operation_lock).and_raise(Errno::EIO)

    expect { accept_registration }.to raise_error(Errno::EIO)
    expect(record.reload.state).to eq('processing')
    expect(@user.notifications).to be_empty
  end

  it '受付状態のDB照合不能を確定失敗に変換せず再受付や通知をしない' do
    record = leave_interrupted_registration
    allow(User).to receive(:lock).and_raise(ActiveRecord::ConnectionNotEstablished, 'synthetic database unavailable')

    expect { accept_registration }.to raise_error(ActiveRecord::ConnectionNotEstablished, 'synthetic database unavailable')
    expect(record.reload.state).to eq('processing')
    expect(@user.receipts).to be_empty
    expect(@user.notifications).to be_empty
  end

  it 'lock取得中に期限を過ぎた停止済み操作を再実行しない' do
    record = leave_interrupted_registration
    allow(Storage).to receive(:with_upload_operation_lock).and_wrap_original do |method, **arguments, &operation|
      travel_to(record.expires_at) { method.call(**arguments, &operation) }
    end

    expect(accept_registration.state).to eq('expired')
    expect(record.reload.state).to eq('processing')
    expect(@user.receipts).to be_empty
  end
end
