require 'rails_helper'

RSpec.describe 'shared/ui/form/_text_field', type: :view do
  before do
    stub_const('TextFieldTestForm', Class.new do
      include ActiveModel::Model

      attr_accessor :password
    end)
  end

  let(:form_object) { TextFieldTestForm.new(password: '') }
  let(:form_builder) { ActionView::Helpers::FormBuilder.new(:text_field_test_form, form_object, view, {}) }

  def render_text_field(**locals)
    render partial: 'shared/ui/form/text_field',
           locals: {
             f: form_builder,
             attribute: :password,
             label: 'Password',
             icon: 'lock',
             field_type: :password_field,
             password_reveal: true
           }.merge(locals)

    Nokogiri::HTML.fragment(rendered)
  end

  it '既定では既存のMaterial Symbolsアイコンを使う' do
    document = render_text_field
    button = document.at_css('button.password-reveal-button')
    icon = button.at_css('[data-password-reveal-target="icon"]')

    aggregate_failures do
      expect(button['class']).to include('password-reveal-button')
      expect(button['class']).not_to include('hover:')
      expect(button['class']).to include('focus-visible:ring-2')
      expect(button['class']).not_to include('focus:ring-2')
      expect(button['data-action']).to include('mousedown->password-reveal#preserveInputFocus')
      expect(button['data-action']).to include('password-reveal#toggle')
      expect(icon['class']).to include('material-symbols-outlined')
      expect(icon.text.strip).to eq('visibility')
      expect(document.at_css('svg.password-visibility-icon')).to be_nil
    end
  end

  it 'オプション指定時だけアニメーションSVGアイコンを使う' do
    document = render_text_field(password_reveal_animation: true)
    button = document.at_css('button.password-reveal-button')
    icon = button.at_css('[data-password-reveal-target="icon"]')

    aggregate_failures do
      expect(icon.name).to eq('svg')
      expect(icon['class']).to include('password-visibility-icon')
      expect(icon['data-animated']).to eq('true')
      expect(icon['data-revealed']).to eq('false')
      expect(icon['aria-hidden']).to eq('true')
      expect(icon.at_css('.password-visibility-icon-eye')).to be_present
      expect(icon.at_css('.password-visibility-icon-pupil')).to be_present
      expect(icon.at_css('.password-visibility-icon-slash')).to be_present
      expect(button.at_css('.material-symbols-outlined')).to be_nil
    end
  end

  it 'password_revealが無効な場合はアニメーション指定があってもボタンを出さない' do
    document = render_text_field(password_reveal: false, password_reveal_animation: true)

    aggregate_failures do
      expect(document.at_css('button.password-reveal-button')).to be_nil
      expect(document.at_css('svg.password-visibility-icon')).to be_nil
    end
  end
end
