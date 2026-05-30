require 'rails_helper'

RSpec.describe 'shared/ui/form/_number_field', type: :view do
  before do
    stub_const('NumberFieldTestForm', Class.new do
      include ActiveModel::Model

      attr_accessor :amount
    end)
  end

  let(:form_object) { NumberFieldTestForm.new(amount: '12') }
  let(:form_builder) { ActionView::Helpers::FormBuilder.new(:number_field_test_form, form_object, view, {}) }

  def render_number_field(**locals)
    render partial: 'shared/ui/form/number_field',
           locals: {
             f: form_builder,
             attribute: :amount,
             label: 'Amount',
             show_label: false
           }.merge(locals)

    Nokogiri::HTML.fragment(rendered).at_css('input[name="number_field_test_form[amount]"]')
  end

  it '中央寄せでsuffixがある場合は左右paddingを均等にする' do
    input = render_number_field(text_align: :center, suffix: '%')

    aggregate_failures do
      expect(input['class']).to include('text-center')
      expect(input['class']).to include('pl-8')
      expect(input['class']).to include('pr-8')
    end
  end

  it '中央寄せでprefixがある場合は左右paddingを均等にする' do
    input = render_number_field(text_align: :center, prefix: '¥')

    aggregate_failures do
      expect(input['class']).to include('text-center')
      expect(input['class']).to include('pl-8')
      expect(input['class']).to include('pr-8')
    end
  end

  it '左寄せのprefix付き入力は既存の非対称paddingを維持する' do
    input = render_number_field(text_align: :left, prefix: '¥')

    aggregate_failures do
      expect(input['class']).to include('text-left')
      expect(input['class']).to include('pl-8')
      expect(input['class']).to include('pr-4')
    end
  end

  it '右寄せのsuffix付き入力は既存の非対称paddingを維持する' do
    input = render_number_field(text_align: :right, suffix: '%')

    aggregate_failures do
      expect(input['class']).to include('text-right')
      expect(input['class']).to include('pl-4')
      expect(input['class']).to include('pr-8')
    end
  end
end
