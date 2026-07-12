require 'rails_helper'

RSpec.describe 'shared/ui/text/_email_address', type: :view do
  def render_email_address(**locals)
    render partial: 'shared/ui/text/email_address', locals: locals

    Nokogiri::HTML.fragment(rendered)
  end

  def email_display(document)
    document.at_css('[data-email-address-display]')
  end

  def direct_segments(display)
    display.children.select(&:element?)
  end

  it 'one_lineは長いlocal-partとdomainの表示契約を保ちraw textをcanonical値にする' do
    email = 'recify-selection-copy-long-local-part-version123456789@example-long-domain.example.com'
    display = email_display(render_email_address(email: email, mode: :one_line))
    segments = direct_segments(display)

    aggregate_failures do
      expect(display.text).to eq(email)
      expect(display.children).to all(be_element)
      expect(display['data-email-address-value']).to eq(email)
      expect(display['title']).to eq(email)
      expect(display['aria-label']).to eq(email)
      expect(display['class'].split).to include('inline-flex', 'w-full', 'whitespace-nowrap')
      expect(segments.map(&:text)).to eq([
        'recify-selection-copy-long-local-part-version123456789',
        '@',
        'example-long-domain.example.com'
      ])
      expect(segments.first['class']).to include('flex-[0_999_auto]', 'truncate')
      expect(segments[1]['class']).to include('shrink-0')
      expect(segments.last['class']).to include('flex-[0_1_auto]', 'truncate')
    end
  end

  it 'two_lineはlocal-partと@domainの表示契約を保ちraw textをcanonical値にする' do
    email = 'recify-selection-copy-two-line@example-long-domain.example.com'
    display = email_display(render_email_address(email: email, mode: :two_line, tag: :p))
    segments = direct_segments(display)

    aggregate_failures do
      expect(display.name).to eq('p')
      expect(display.text).to eq(email)
      expect(display.children).to all(be_element)
      expect(display['data-email-address-value']).to eq(email)
      expect(display['class'].split).to include('inline-flex', 'w-full', 'flex-wrap')
      expect(display['class'].split).not_to include('whitespace-nowrap')
      expect(segments.map(&:text)).to eq([
        'recify-selection-copy-two-line',
        '@example-long-domain.example.com'
      ])
      expect(segments).to all(satisfy { |segment| segment['class'].include?('truncate') })
    end
  end

  it 'full_width falseは親flex内の残り幅を使う契約を維持する' do
    email = 'pending-selection-copy@example.com'
    display = email_display(
      render_email_address(
        email: email,
        mode: :one_line,
        full_width: false,
        class: 'min-w-0 flex-1 token-text-warning'
      )
    )

    aggregate_failures do
      expect(display.text).to eq(email)
      expect(display['class'].split).to include('min-w-0', 'max-w-full', 'flex-1', 'token-text-warning')
      expect(display['class'].split).not_to include('w-full')
    end
  end

  it 'copyable表示は表示値とhidden sourceをcanonical値のまま維持する' do
    email = 'copyable-selection-copy@example-long-domain.example.com'
    document = render_email_address(
      email: email,
      mode: :one_line,
      tag: :p,
      copyable: true,
      copy_label: 'メールアドレス',
      class: 'token-text-base'
    )
    wrapper = document.at_css('p[title]')
    display = email_display(document)
    source = document.at_css('[data-clipboard-target="source"]')
    button = document.at_css('button[data-action="click->clipboard#copy"]')

    aggregate_failures do
      expect(wrapper['title']).to eq(email)
      expect(wrapper['aria-label']).to eq(email)
      expect(display.text).to eq(email)
      expect(display.children).to all(be_element)
      expect(display['data-email-address-value']).to eq(email)
      expect(source.text).to eq(email)
      expect(button['aria-label']).to eq(I18n.t('shared.clipboard.copy_label', label: 'メールアドレス'))
    end
  end

  it 'メール形式でない表示値も余分なtext nodeを含めない' do
    text = I18n.t('users.display.email_unregistered')
    display = email_display(render_email_address(email: text, mode: :one_line))

    aggregate_failures do
      expect(display.text).to eq(text)
      expect(display.children).to all(be_element)
      expect(direct_segments(display).map(&:text)).to eq([ text ])
    end
  end
end
