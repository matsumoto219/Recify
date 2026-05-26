require 'rails_helper'

RSpec.describe AuditLog, type: :model do
  it 'admin actionの監査ログを作成できる' do
    log = build(:audit_log)

    expect(log).to be_valid
  end

  it 'system actionの監査ログを作成できる' do
    log = build(:audit_log, :system)

    expect(log).to be_valid
  end

  it 'actor_user削除時もaudit logを残してactor_user_idをnullにする' do
    actor = create(:user)
    log = create(:audit_log, actor_user: actor)

    actor.destroy!

    expect(log.reload.actor_user).to be_nil
  end

  it 'actor_kindを制限する' do
    log = build(:audit_log, actor_kind: 'support')

    expect(log).not_to be_valid
    expect(log.errors[:actor_kind]).to be_present
  end

  it 'outcomeを制限する' do
    log = build(:audit_log, outcome: 'pending')

    expect(log).not_to be_valid
    expect(log.errors[:outcome]).to be_present
  end

  it 'actionを必須にする' do
    log = build(:audit_log, action: nil)

    expect(log).not_to be_valid
    expect(log.errors[:action]).to be_present
  end

  it 'json fieldsは空Hashをdefaultにする' do
    log = described_class.create!(
      actor_kind: 'system',
      action: 'receipt_analysis.retention_cleanup',
      outcome: 'succeeded'
    )

    expect(log.metadata).to eq({})
    expect(log.before_state).to eq({})
    expect(log.after_state).to eq({})
  end

  it 'json fieldsはHashだけ許可する' do
    log = build(:audit_log, metadata: [ 'unsafe' ])

    expect(log).not_to be_valid
    expect(log.errors[:metadata]).to be_present
  end
end
