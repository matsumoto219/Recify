require 'rails_helper'

RSpec.describe 'Account deletion and receipt registration' do
  self.use_transactional_tests = false

  before do
    @user = create(:user)
  end

  after do
    ReceiptRegistrationOperation.where(user_id: @user.id).delete_all
    User.find_by(id: @user.id)&.destroy!
  end

  def join_thread(thread)
    Timeout.timeout(5) { thread.value }
  end

  it '子recordの削除前にUser rowをlockし別connectionの受付lockを排除する' do
    competing_lock = nil
    allow(@user).to receive(:destroy!).and_wrap_original do |original|
      competing_lock = join_thread(Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User.transaction(requires_new: true) { User.lock('FOR UPDATE NOWAIT').find(@user.id) }
          :unlocked
        rescue ActiveRecord::LockWaitTimeout
          :locked
        end
      end)
      original.call
    end

    Users.delete_account(user: @user)

    expect(competing_lock).to eq(:locked)
  end

  it '受付処理中に本人削除が先行した場合は最終受付もReceiptも残さない' do
    token = Receipts::Registrations.issue_token(user: @user, kind: 'manual')

    expect do
      Receipts::Registrations.with_operation(user: @user, token: token, kind: 'manual', input: {}) do |operation|
        join_thread(Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Users.delete_account(user: User.find(@user.id))
          end
        end)
        Receipt.transaction { Receipts::Registrations.accept!(operation: operation, receipts: []) }
      end
    end.to raise_error(Receipts::Registrations::InvalidOperation)

    aggregate_failures do
      expect(User.exists?(@user.id)).to be(false)
      expect(ReceiptRegistrationOperation.where(user_id: @user.id)).not_to exist
      expect(Receipt.where(user_id: @user.id)).not_to exist
      expect(UsageCounter.where(user_id: @user.id)).not_to exist
    end
  end

  it '先に確定した受付とReceiptは後続の本人削除方針で一緒に削除する' do
    token = Receipts::Registrations.issue_token(user: @user, kind: 'manual')
    accepted = Receipts::Registrations.with_operation(user: @user, token: token, kind: 'manual', input: {}) do |operation|
      Receipt.transaction do
        User.lock.find(@user.id)
        receipt = create(:receipt, user: @user)
        Usage.consume_manual_receipt!(user: @user)
        Receipts::Registrations.accept!(operation: operation, receipts: [ receipt ])
      end
      true
    end

    result = Users.delete_account(user: @user)

    aggregate_failures do
      expect(accepted).to be_accepted
      expect(result.summary[:receipts_count]).to eq(1)
      expect(ReceiptRegistrationOperation.where(user_id: @user.id)).not_to exist
      expect(Receipt.where(user_id: @user.id)).not_to exist
      expect(UsageCounter.where(user_id: @user.id)).not_to exist
    end
  end
end
