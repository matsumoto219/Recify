require 'rails_helper'

RSpec.describe 'shared/ui/actions/_button', type: :view do
  def render_button(**locals)
    render partial: 'shared/ui/actions/button', locals: { label: '確認' }.merge(locals)

    Nokogiri::HTML.fragment(rendered)
  end

  it 'unstyled link uses the existing variant option for link color' do
    document = render_button(
      as: :link,
      href: '#target',
      variant: :primary,
      unstyled: true,
      class: 'text-xs font-bold'
    )
    link = document.at_css('a[href="#target"]')

    aggregate_failures do
      expect(link['class']).to include('btn-link-primary')
      expect(link['class']).not_to include('btn-primary')
      expect(link['class']).not_to include('rounded-lg')
    end
  end

  it 'unstyled danger link keeps danger color intent without button chrome' do
    document = render_button(as: :link, href: '#danger', variant: :danger, unstyled: true)
    link = document.at_css('a[href="#danger"]')

    aggregate_failures do
      expect(link['class']).to include('btn-link-danger')
      expect(link['class']).not_to include('btn-danger')
      expect(link['class']).not_to include('border')
    end
  end

  it 'unstyled warning link keeps warning color intent without button chrome' do
    document = render_button(as: :link, href: '#warning', variant: :warning, unstyled: true)
    link = document.at_css('a[href="#warning"]')

    aggregate_failures do
      expect(link['class']).to include('btn-link-warning')
      expect(link['class']).not_to include('btn-warning')
      expect(link['class']).not_to include('border')
    end
  end

  it 'styled warning buttons use warning variant classes' do
    document = render_button(variant: :warning)
    button = document.at_css('button')

    aggregate_failures do
      expect(button['class']).to include('btn-warning')
      expect(button['class']).to include('border')
      expect(button['class']).not_to include('btn-link-warning')
    end
  end

  it 'styled buttons continue to use button variant classes' do
    document = render_button(variant: :secondary)
    button = document.at_css('button')

    aggregate_failures do
      expect(button['class']).to include('btn-secondary')
      expect(button['class']).to include('border')
      expect(button['class']).not_to include('btn-link-secondary')
    end
  end
end
