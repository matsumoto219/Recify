require 'rails_helper'

RSpec.describe 'Receipt upload failure notifications' do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:token) { Receipts::Registrations.issue_token(user: user, kind: 'upload') }

  def failed_operation(kind: 'upload', token: self.token)
    handle = nil
    Receipts::Registrations.with_operation(user: user, token: token, kind: kind, input: []) do |operation|
      handle = operation
      false
    end
    handle
  end

  def report(operation, reason: 'storage_failed')
    Receipts::Registrations.report_failure(operation: operation, reason: reason)
  end

  it '未受付の保存失敗を通常通知へ一度だけ記録しReceiptや利用回数を作らない' do
    operation = failed_operation

    expect(report(operation)).to be(true)
    notification = user.notifications.sole
    record = ReceiptRegistrationOperation.find(operation.id)

    aggregate_failures do
      expect(notification.kind).to eq('receipt_upload_failed')
      expect(notification.notifiable).to eq(record)
      expect(notification.action_path).to eq('/receipts/new_upload')
      expect(notification).to be_unread
      expect(record.state).to eq('failed')
      expect(record.notification_reported).to be(true)
      expect(notification.metadata).to eq('reason' => 'storage_failed')
      expect(notification.body).to include('アップロードに失敗しました。画像を選び直して再送してください。', 'storage_failed')
      expect(notification.attributes.to_json).not_to include(token, operation.operation_key, operation.attempt_key)
      expect(user.receipts).to be_empty
      expect(UsageCounter.where(user: user)).to be_empty
      expect(report(operation)).to be(true)
      expect(user.notifications.count).to eq(1)
    end
  end

  it 'batchの保存失敗も通知は1件だけでOCRフォームへ戻す' do
    operation = failed_operation(kind: 'batch_upload')
    2.times { report(operation) }

    expect(user.notifications.count).to eq(1)
    expect(user.notifications.sole.action_path).to eq('/receipts/new_upload')
  end

  it '画像付きmanualの失敗通知は元の手動フォームへ戻す' do
    manual_token = Receipts::Registrations.issue_token(user: user, kind: 'manual')
    report(failed_operation(kind: 'manual', token: manual_token))

    expect(user.notifications.sole.action_path).to eq('/receipts/new')
  end

  it '通知を読んだ後も未読へ戻さず削除後も再生成しない' do
    operation = failed_operation
    report(operation)
    notification = user.notifications.sole
    notification.mark_as_read!
    read_at = notification.read_at

    expect(report(operation)).to be(true)
    expect(notification.reload.read_at).to eq(read_at)
    notification.destroy!

    expect(report(operation)).to be(true)
    expect(user.notifications).to be_empty
  end

  it '通常の件数整理で通知が削除されても再生成しない' do
    operation = failed_operation
    report(operation)
    user.notifications.delete_all

    expect(report(operation)).to be(true)
    expect(user.notifications).to be_empty
  end

  it '通常の失敗結果だけでは通知せず未知の理由やraw例外も拒否する' do
    operation = failed_operation
    expect(user.notifications).to be_empty

    [ nil, 'validation_failed', 'quota_exceeded', 'processing', 'response_unknown', 'private error' ].each do |reason|
      expect(report(operation, reason: reason)).to be(false)
    end

    expect(user.notifications).to be_empty
    expect(ReceiptRegistrationOperation.find(operation.id).notification_reported).to be(false)
  end

  it '受付済み操作では応答喪失や解析enqueue失敗があっても通知しない' do
    handle = nil
    receipt = create(:receipt, user: user)
    Receipts::Registrations.with_operation(user: user, token: token, kind: 'upload', input: []) do |operation|
      handle = operation
      Receipts::Registrations.accept!(operation: operation, receipts: [ receipt ])
    end

    expect(report(handle)).to be(false)
    expect(user.notifications).to be_empty
    expect(ReceiptRegistrationOperation.find(handle.id).state).to eq('accepted')
  end

  it '現在の失敗試行だけを通知でき旧attemptや別ownerのhandleは拒否する' do
    previous = failed_operation
    current = failed_operation
    other_owner = current.with(user_id: create(:user).id)
    other_key = current.with(operation_key: 'a' * 64)

    expect(report(previous)).to be(false)
    expect(report(other_owner)).to be(false)
    expect(report(other_key)).to be(false)
    expect(report(nil)).to be(false)
    expect(user.notifications).to be_empty
    expect(report(current)).to be(true)
  end

  it '通知保存不能でも元の失敗結果を変えず通知済みflagを残さない' do
    operation = failed_operation
    allow_any_instance_of(Notification).to receive(:save!).and_raise(ActiveRecord::RecordNotSaved, 'private failure')
    expect(Rails.logger).to receive(:warn).with('[ReceiptRegistration] notification_failed error_class=ActiveRecord::RecordNotSaved')

    expect(report(operation)).to be(false)
    expect(user.notifications).to be_empty
    record = ReceiptRegistrationOperation.find(operation.id)
    expect(record.state).to eq('failed')
    expect(record.notification_reported).to be(false)
  end

  it '受付記録cleanup後も通常通知の履歴と元フォームへの導線を保持する' do
    operation = failed_operation
    report(operation)
    notification = user.notifications.sole
    notification.mark_as_read!
    metadata = notification.metadata.deep_dup

    travel 24.hours do
      expect(Receipts::Registrations.cleanup_expired.deleted).to eq(1)
      expect(notification.reload.notifiable).to be_nil
      expect(notification).to be_read
      expect(notification.metadata).to eq(metadata)
      expect(notification.action_path).to eq('/receipts/new_upload')
      expect(notification).to be_action_available
      expect(report(operation)).to be(false)
      expect(user.notifications.count).to eq(1)
    end
  end

  it '削除済みaccountの操作で通知を新設しない' do
    operation = failed_operation
    user.destroy!

    expect(report(operation)).to be(false)
    expect(Notification.count).to eq(0)
  end

  it '実行中でも呼出し側が確定した保存失敗だけを通知し受付できない状態にする' do
    result = Receipts::Registrations.with_operation(user: user, token: token, kind: 'upload', input: []) do |operation|
      expect(user.notifications).to be_empty
      expect(report(operation)).to be(true)
      expect(ReceiptRegistrationOperation.find(operation.id).state).to eq('failed')
      false
    end

    expect(result.state).to eq('failed')
    expect(user.notifications.count).to eq(1)
  end
end
