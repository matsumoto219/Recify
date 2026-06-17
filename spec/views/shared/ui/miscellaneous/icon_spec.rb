require 'rails_helper'

RSpec.describe 'shared/ui/miscellaneous/_icon', type: :view do
  it 'brand logoのicon only表示を描画する' do
    render partial: 'shared/ui/miscellaneous/icon'

    document = Nokogiri::HTML.fragment(rendered)
    surface = document.at_css('.auth-icon-surface')
    logo = surface.at_css('span.brand-logo')

    aggregate_failures do
      expect(surface).to be_present
      expect(logo['role']).to eq('img')
      expect(logo['aria-label']).to eq('Recify')
      expect(logo['class']).to include('brand-logo-icon')
      expect(logo['class']).to include('brand-logo-lg')
      expect(logo.at_css('.brand-logo-mark')['aria-hidden']).to eq('true')
      expect(logo.at_css('.brand-logo-text')).to be_nil
      expect(document.at_css('.material-symbols-outlined')).to be_nil
    end
  end
end
