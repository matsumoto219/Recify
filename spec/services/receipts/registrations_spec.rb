require 'rails_helper'

RSpec.describe Receipts::Registrations do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }
  let(:token) { described_class.issue_token(user: user, kind: 'manual') }
  let(:input) { { 'memo' => '受付テスト' } }

  def accept_registration(token: self.token, input: self.input)
    described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do |operation|
      Receipt.transaction do
        User.lock.find(user.id)
        receipt = create(:receipt, user: user)
        Usage.consume_manual_receipt!(user: user)
        described_class.accept!(operation: operation, receipts: [ receipt ])
      end
      :saved_result
    end
  end

  it '初回受付と利用回数を保存し同じ操作の再送は実行しない' do
    first = accept_registration
    second = described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do
      raise 'replay must not execute'
    end

    aggregate_failures do
      expect(first).to be_accepted
      expect(first.value).to eq(:saved_result)
      expect(first).not_to be_replayed
      expect(second).to be_accepted
      expect(second).to be_replayed
      expect(second.receipt_ids).to eq(first.receipt_ids)
      expect(user.receipts.count).to eq(1)
      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(1)
    end
  end

  it '別の操作なら同じ入力も登録できる' do
    accept_registration
    second = accept_registration(token: described_class.issue_token(user: user, kind: 'manual'))

    expect(second).to be_accepted
    expect(user.receipts.count).to eq(2)
  end

  it '受付済み操作は日付を跨ぎ上限が変わっても再実行しない' do
    travel_to(Time.zone.local(2026, 10, 13, 23, 59)) do
      issued_token = described_class.issue_token(user: user, kind: 'manual')
      first = accept_registration(token: issued_token)
      previous_counter = UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day')
      travel 2.minutes
      expect(Usage).not_to receive(:consume_manual_receipt!)
      expect(Receipts::Processing).not_to receive(:start)

      result = described_class.with_operation(user: user, token: issued_token, kind: 'manual', input: input) do
        raise 'accepted replay must not execute'
      end

      expect(result.receipt_ids).to eq(first.receipt_ids)
      expect(previous_counter.reload.used_count).to eq(1)
      expect(UsageCounter.where(user: user).count).to eq(1)
    end
  end

  it '同じIDの別入力と種別変更を実行しない' do
    accept_registration
    changed = described_class.with_operation(user: user, token: token, kind: 'manual', input: { 'memo' => '変更' }) do
      raise 'conflicting input must not execute'
    end
    wrong_kind = described_class.with_operation(user: user, token: token, kind: 'upload', input: input) do
      raise 'conflicting kind must not execute'
    end

    expect(changed.state).to eq('conflict')
    expect(wrong_kind.state).to eq('conflict')
  end

  it '明示acceptなしのfalseを受付成功にせず同入力を再試行できる' do
    first = described_class.with_operation(user: user, token: token, kind: 'manual', input: input) { false }
    second = accept_registration

    expect(first.state).to eq('failed')
    expect(first.value).to be(false)
    expect(second).to be_accepted
    expect(user.receipts.count).to eq(1)
  end

  it '最終transactionの例外はreceipt・counter・受付をrollbackし例外を伝播する' do
    expect do
      described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do |operation|
        Receipt.transaction(requires_new: true) do
          User.lock.find(user.id)
          receipt = create(:receipt, user: user)
          Usage.consume_manual_receipt!(user: user)
          described_class.accept!(operation: operation, receipts: [ receipt ])
          raise IOError, 'injected failure'
        end
      end
    end.to raise_error(IOError, 'injected failure')

    aggregate_failures do
      expect(user.receipts).to be_empty
      expect(UsageCounter.where(user: user)).to be_empty
      expect(user.receipt_registration_operations.sole.state).to eq('failed')
      expect(accept_registration).to be_accepted
    end
  end

  it '受付済みreceipt削除後の同一フォーム再送も再登録せず結果IDだけを返す' do
    first = accept_registration
    Receipt.find(first.receipt_ids.sole).destroy!
    expect(Receipts::Processing).not_to receive(:start)

    result = described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do
      raise 'deleted receipt must not be recreated'
    end

    expect(result).to be_accepted
    expect(result.receipt_ids).to eq(first.receipt_ids)
    expect(user.receipts).to be_empty
  end

  it 'フォームtokenの発行だけでは受付行や通知を作成しない' do
    expect(Receipts::Processing).not_to receive(:start)

    expect(token).to be_present
    expect(ReceiptRegistrationOperation.count).to eq(0)
    expect(Notification.count).to eq(0)
  end

  it '他人のtokenと期限切れtokenを受付行がなくても拒否する' do
    issued_token = token
    other = create(:user)
    result = described_class.with_operation(user: other, token: issued_token, kind: 'manual', input: input) do
      raise 'another owner must not execute'
    end
    expect(result.state).to eq('invalid')

    travel 24.hours do
      result = described_class.with_operation(user: user, token: issued_token, kind: 'manual', input: input) do
        raise 'expired operation must not execute'
      end
      expect(result.state).to eq('expired')
      expect(ReceiptRegistrationOperation.count).to eq(0)
    end
  end

  it '期限後に受付記録を回収しても古いtokenを新しい操作として使えない' do
    issued_token = token
    accept_registration(token: issued_token)

    travel 24.hours do
      expect(described_class.cleanup_expired.deleted).to eq(1)
      result = described_class.with_operation(user: user, token: issued_token, kind: 'manual', input: input) do
        raise 'expired operation must not be recreated'
      end

      expect(result.state).to eq('expired')
      expect(ReceiptRegistrationOperation.count).to eq(0)
      expect(user.receipts.count).to eq(1)
      expect(UsageCounter.find_by!(user: user, key: 'manual_receipts_per_day').used_count).to eq(1)
    end
  end

  it '現在処理中の操作は非blockingで返して二重実行しない' do
    described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do
      result = described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do
        raise 'concurrent operation must not execute'
      end
      expect(result.state).to eq('processing')
      false
    end
  end

  it '停止した旧attemptからの受付を新しい試行内で拒否する' do
    old_operation = nil
    described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do |operation|
      old_operation = operation
      false
    end

    described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do
      Receipt.transaction(requires_new: true) do
        receipt = create(:receipt, user: user)
        expect do
          described_class.accept!(operation: old_operation, receipts: [ receipt ])
        end.to raise_error(Receipts::Registrations::InvalidOperation, 'registration operation unavailable')
        raise ActiveRecord::Rollback
      end
      false
    end
    expect(user.receipts).to be_empty
  end

  it '受付確定時にも期限とReceipt所有者を再確認する' do
    other = create(:user)
    other_receipt = create(:receipt, user: other)
    described_class.with_operation(user: user, token: token, kind: 'manual', input: input) do |operation|
      expect do
        described_class.accept!(operation: operation, receipts: [ other_receipt ])
      end.to raise_error(Receipts::Registrations::InvalidOperation)

      travel 24.hours do
        expect do
          described_class.accept!(operation: operation, receipts: [ other_receipt ])
        end.to raise_error(Receipts::Registrations::InvalidOperation)
      end
      false
    end
  end
end
