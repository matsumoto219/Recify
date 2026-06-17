require 'rails_helper'

RSpec.describe 'shared/brand/_logo', type: :view do
  def render_logo(**locals)
    render partial: 'shared/brand/logo', locals: locals

    Nokogiri::HTML.fragment(rendered)
  end

  it 'full variantはRecify textをHTMLとして出力する' do
    document = render_logo
    logo = document.at_css('a.brand-logo')
    mark = logo.at_css('.brand-logo-mark')
    text = logo.at_css('.brand-logo-text')

    aggregate_failures do
      expect(logo['href']).to eq(root_path)
      expect(logo['aria-label']).to eq('Recify')
      expect(logo['class']).to include('brand-logo-full')
      expect(logo['style']).to include('--brand-icon-url')
      expect(logo['style']).to include('brand/recify-icon')
      expect(mark['aria-hidden']).to eq('true')
      expect(text.text).to eq('Recify')
    end
  end

  it 'icon variantはtextを表示しない' do
    document = render_logo(variant: :icon, size: :sm)
    logo = document.at_css('a.brand-logo')

    aggregate_failures do
      expect(logo['aria-label']).to eq('Recify')
      expect(logo['class']).to include('brand-logo-icon')
      expect(logo['class']).to include('brand-logo-sm')
      expect(logo.at_css('.brand-logo-mark')['aria-hidden']).to eq('true')
      expect(logo.at_css('.brand-logo-text')).to be_nil
      expect(document.text.strip).to eq('')
    end
  end

  it 'href nilならspan wrapperとして表示する' do
    document = render_logo(href: nil, variant: :compact, label: 'Recify')
    logo = document.at_css('span.brand-logo')

    aggregate_failures do
      expect(document.at_css('a.brand-logo')).to be_nil
      expect(logo['role']).to eq('img')
      expect(logo['aria-label']).to eq('Recify')
      expect(logo['class']).to include('brand-logo-compact')
      expect(logo.at_css('.brand-logo-text').text).to eq('Recify')
    end
  end
end
