require 'rails_helper'

RSpec.describe ApplicationMailer, type: :mailer do
  describe 'mailer brand icon' do
    it 'CID添付用アイコンは透明背景のグラデーションPNGにする' do
      require 'chunky_png'

      icon = ChunkyPNG::Image.from_file(described_class::BRAND_ICON_PATH.to_s)
      top_sample = icon[40, 28]
      bottom_sample = icon[80, 150]

      aggregate_failures do
        expect(described_class::BRAND_ICON_PATH).to exist
        expect(icon.dimension.width).to eq(192)
        expect(icon.dimension.height).to eq(192)
        expect(ChunkyPNG::Color.a(icon[0, 0])).to eq(0)
        expect(ChunkyPNG::Color.a(icon[191, 191])).to eq(0)
        expect(ChunkyPNG::Color.a(top_sample)).to be > 0
        expect(ChunkyPNG::Color.a(bottom_sample)).to be > 0
        expect(top_sample).not_to eq(bottom_sample)
      end
    end
  end

  describe 'recipient names' do
    let(:mailer) { described_class.new }

    it '問い合わせ宛名はsender_nameを優先する' do
      user = build(:user, name: '登録名')
      contact_request = build(:contact_request, sender_name: '入力名', user: user, email: 'sender@example.com')

      expect(mailer.send(:contact_request_recipient_name, contact_request)).to eq('入力名')
    end

    it '問い合わせ宛名はsender_nameなしならuser.nameを使う' do
      user = build(:user, name: '登録名')
      contact_request = build(:contact_request, sender_name: nil, user: user, email: 'sender@example.com')

      expect(mailer.send(:contact_request_recipient_name, contact_request)).to eq('登録名')
    end

    it '問い合わせ宛名はsender_name/user.nameなしならemailを使う' do
      user = build(:user, name: '')
      contact_request = build(:contact_request, sender_name: nil, user: user, email: 'sender@example.com')

      expect(mailer.send(:contact_request_recipient_name, contact_request)).to eq('sender@example.com')
    end

    it 'Devise宛名はuser.nameを優先する' do
      user = build(:user, name: '登録名', email: 'user@example.com')

      expect(mailer.send(:devise_recipient_name, user, delivery_email: user.email)).to eq('登録名')
    end

    it 'Devise宛名はuser.nameなしなら実送信先emailを使う' do
      user = build(:user, name: '', email: 'user@example.com')

      expect(mailer.send(:devise_recipient_name, user, delivery_email: user.email)).to eq('user@example.com')
    end

    it 'Devise宛名はguest fake emailではなく実送信先emailをfallbackにする' do
      guest = build(:user, guest: true, name: '', email: 'guest_fake@example.com')

      recipient_name = mailer.send(:devise_recipient_name, guest, delivery_email: 'guest-registration@example.com')

      aggregate_failures do
        expect(recipient_name).to eq('guest-registration@example.com')
        expect(recipient_name).not_to eq(guest.email)
      end
    end
  end
end
