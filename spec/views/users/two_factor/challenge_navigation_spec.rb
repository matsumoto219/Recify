require 'rails_helper'

RSpec.describe 'users/two_factor/_challenge_navigation', type: :view do
  def render_navigation(allowed_methods:, current_method:)
    render partial: 'users/two_factor/challenge_navigation', locals: {
      allowed_methods: allowed_methods,
      current_method: current_method,
      back_label: 'ログイン画面に戻る'
    }
  end

  it '許可済みの代替手段だけを固定順で表示する' do
    render_navigation(
      allowed_methods: %w[recovery_code unknown totp passkey recovery_code],
      current_method: 'passkey'
    )

    document = Nokogiri::HTML.fragment(rendered)
    links = document.css('a')

    aggregate_failures do
      expect(links.map { |link| link['href'] }).to eq([
        users_two_factor_totp_path,
        users_two_factor_recovery_code_path,
        new_user_session_path
      ])
      expect(links.map(&:text)).to eq([
        I18n.t('auth.two_factor.links.totp'),
        I18n.t('auth.two_factor.links.recovery_code'),
        'ログイン画面に戻る'
      ])
      expect(rendered).to include(I18n.t('auth.two_factor.links.heading'))
      expect(rendered).not_to include('unknown')
    end
  end

  it '有効な代替手段がない場合もlogin導線だけを表示する' do
    render_navigation(allowed_methods: %w[passkey unknown], current_method: 'passkey')

    document = Nokogiri::HTML.fragment(rendered)
    links = document.css('a')

    aggregate_failures do
      expect(links.map { |link| link['href'] }).to eq([ new_user_session_path ])
      expect(links.map(&:text)).to eq([ 'ログイン画面に戻る' ])
      expect(rendered).not_to include(I18n.t('auth.two_factor.links.heading'))
    end
  end
end
