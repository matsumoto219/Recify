require 'rails_helper'

RSpec.describe Admin::ContactRequestsQuery do
  describe '.call' do
    it '問い合わせ一覧用recordを返し、返信先はmasked表示にする' do
      user = create(:user, email: 'user@example.com')
      contact_request = create(
        :contact_request,
        user: user,
        email: 'sender@example.com',
        category: 'security',
        status: 'open',
        source: 'authenticated',
        sender_name: '送信 太郎',
        subject: '安全性の相談'
      )

      result = described_class.call(status: 'open')
      record = result.records.find { |item| item[:id] == contact_request.id }

      aggregate_failures do
        expect(record[:request_uid]).to eq(contact_request.request_uid)
        expect(record[:email_masked]).to eq('se***@example.com')
        expect(record[:email_masked]).not_to eq('sender@example.com')
        expect(record[:email_digest]).to eq(contact_request.email_digest)
        expect(record[:user_id]).to eq(user.id)
        expect(record[:sender_name]).to eq('送信 太郎')
      end
    end

    it 'status/category/source/user_id/email_digest/request_uidでfilterできる' do
      target = create(:contact_request, category: 'bug', status: 'in_progress', source: 'public')
      create(:contact_request, category: 'account', status: 'open', source: 'public')

      result = described_class.call(
        status: 'in_progress',
        category: 'bug',
        source: 'public',
        user_id: target.user_id,
        email_digest: target.email_digest,
        request_uid: target.request_uid
      )

      expect(result.records.map { |record| record[:id] }).to contain_exactly(target.id)
    end

    it 'limitを上限で丸める' do
      create_list(:contact_request, 3)

      result = described_class.call(limit: 1000)

      expect(result.limit).to eq(described_class::MAX_LIMIT)
    end
  end
end
