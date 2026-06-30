require 'rails_helper'

RSpec.describe 'Public layout stylesheet' do
  let(:source) { Rails.root.join('app/assets/tailwind/application.css').read }

  it '認証ページ本体を実ビューポート基準の高さに保つ' do
    aggregate_failures do
      expect(source).to include('.auth-page-shell-standalone')
      expect(source).to include('min-height: 100svh;')
      expect(source).to include('@supports (min-height: 100dvh)')
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
