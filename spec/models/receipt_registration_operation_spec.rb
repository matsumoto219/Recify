require 'rails_helper'

RSpec.describe ReceiptRegistrationOperation, type: :model do
  let(:user) { create(:user) }
  let(:attributes) do
    issued_at = Time.current
    {
      user: user,
      operation_key: 'a' * 64,
      kind: 'manual',
      state: 'processing',
      input_fingerprint: 'b' * 64,
      attempt_key: 'c' * 32,
      issued_at: issued_at,
      expires_at: issued_at + 24.hours,
      receipt_ids: []
    }
  end

  it '同じuserと操作IDの一意性をDBでも保証する' do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it '受付状態と結果参照の組合せをDBでも拒否する' do
    record = described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        record.update_columns(state: 'accepted', accepted_at: Time.current)
      end
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it '期限と結果件数とidentifierをboundedにする' do
    aggregate_failures do
      expect(described_class.new(attributes.merge(expires_at: 25.hours.from_now))).not_to be_valid
      expect(described_class.new(attributes.merge(attempt_key: 'private-input'))).not_to be_valid
      expect(described_class.new(attributes.merge(state: 'accepted', accepted_at: Time.current, receipt_ids: (1..21).to_a)))
        .not_to be_valid
      expect(described_class.new(attributes.merge(state: 'accepted', accepted_at: Time.current, receipt_ids: [ 1, 1 ])))
        .not_to be_valid
    end
  end

  it '未送信のpendingを受け付けず全操作で入力と試行の識別子を必須にする' do
    aggregate_failures do
      expect(described_class.new(attributes.merge(state: 'pending', input_fingerprint: nil, attempt_key: nil))).not_to be_valid
      expect(described_class.new(attributes.merge(input_fingerprint: nil))).not_to be_valid
      expect(described_class.new(attributes.merge(attempt_key: nil))).not_to be_valid
    end
  end

  it '未送信pending状態をDBでも拒否する' do
    record = described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        record.update_columns(state: 'pending', input_fingerprint: nil, attempt_key: nil)
      end
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it '入力と試行の識別子の欠落をDBでも拒否する' do
    record = described_class.create!(attributes)

    %i[input_fingerprint attempt_key].each do |attribute|
      expect do
        described_class.transaction(requires_new: true) do
          record.update_columns(attribute => nil)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end
end
