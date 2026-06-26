require 'rails_helper'

RSpec.describe 'Public layout stylesheet' do
  let(:source) { Rails.root.join('app/assets/tailwind/application.css').read }

  it '認証ページ本体の高さを伸ばしてカード影の下部余白を確保する' do
    aggregate_failures do
      expect(source).to include('.auth-page-shell-standalone')
      expect(source).to include('--auth-page-footer-shadow-buffer: clamp(2.5rem, 6vh, 4rem);')
      expect(source).to include('min-height: calc(100vh + var(--auth-page-footer-shadow-buffer));')
    end
  end

  it '公開フッターのグラデーション強度を維持する' do
    aggregate_failures do
      expect(source).to include('--public-footer-gradient-start: transparent;')
      expect(source).to include('--public-footer-gradient-end: var(--browser-chrome-bg);')
      expect(source).to include('.public-footer-shell')
    end
  end
end
