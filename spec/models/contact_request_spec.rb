require 'rails_helper'

RSpec.describe ContactRequest do
  describe 'validations' do
    it '有効な問い合わせを許可する' do
      contact_request = build(:contact_request)

      expect(contact_request).to be_valid
    end

    it 'request_uidを自動生成し、一意性を検証する' do
      existing = create(:contact_request)
      duplicate = build(:contact_request, request_uid: existing.request_uid)

      aggregate_failures do
        expect(build(:contact_request, request_uid: nil)).to be_valid
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:request_uid]).to be_present
      end
    end

    it 'email形式を検証する' do
      contact_request = build(:contact_request, email: 'not-an-email')

      expect(contact_request).not_to be_valid
      expect(contact_request.errors[:email]).to be_present
    end

    it 'sender_nameを正規化し、長さを検証する' do
      contact_request = build(:contact_request, sender_name: '  山田 太郎  ')
      too_long = build(:contact_request, sender_name: 'あ' * 51)
      blank = build(:contact_request, sender_name: '   ')

      aggregate_failures do
        expect(contact_request).to be_valid
        expect(contact_request.sender_name).to eq('山田 太郎')
        expect(too_long).not_to be_valid
        expect(too_long.errors[:sender_name]).to be_present
        expect(blank).to be_valid
        expect(blank.sender_name).to be_nil
      end
    end

    it 'category / status / sourceのallowlistを検証する' do
      contact_request = build(:contact_request, category: 'secret', status: 'deleted', source: 'crawler')

      expect(contact_request).not_to be_valid
      expect(contact_request.errors[:category]).to be_present
      expect(contact_request.errors[:status]).to be_present
      expect(contact_request.errors[:source]).to be_present
    end

    it 'subjectとbodyの長さを検証する' do
      contact_request = build(:contact_request, subject: 'a' * 161, body: 'b' * 5001)

      expect(contact_request).not_to be_valid
      expect(contact_request.errors[:subject]).to be_present
      expect(contact_request.errors[:body]).to be_present
    end
  end
end
