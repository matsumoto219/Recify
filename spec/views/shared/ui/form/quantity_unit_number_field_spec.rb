require 'rails_helper'

RSpec.describe 'shared/ui/form/_quantity_unit_number_field', type: :view do
  before do
    stub_const('QuantityUnitNumberFieldTestForm', Class.new do
      include ActiveModel::Model

      attr_accessor :quantity, :quantity_unit_code
    end)
  end

  let(:form_object) do
    QuantityUnitNumberFieldTestForm.new(quantity: '8.12', quantity_unit_code: 'set')
  end
  let(:form_builder) do
    ActionView::Helpers::FormBuilder.new(:quantity_unit_number_field_test_form, form_object, view, {})
  end
  let(:unit_options) do
    [
      [ '個', 'each' ],
      [ 'セット', 'set' ],
      [ 'kg', 'kilogram' ]
    ]
  end

  def render_quantity_unit_number_field(**locals)
    render partial: 'shared/ui/form/quantity_unit_number_field',
           locals: {
             f: form_builder,
             label: '数量',
             value: form_object.quantity,
             selected_unit: form_object.quantity_unit_code,
             unit_options: unit_options,
             show_label: false
           }.merge(locals)

    Nokogiri::HTML.fragment(rendered)
  end

  it 'compact表示ではdesktopの単位幅を内容に合わせ、数量欄と折り返せる' do
    document = render_quantity_unit_number_field(unit_select_variant: :compact_suffix)
    input = document.at_css('input[name="quantity_unit_number_field_test_form[quantity]"]')
    select = document.at_css('select[name="quantity_unit_number_field_test_form[quantity_unit_code]"]')
    wrapper = input.parent.parent

    aggregate_failures do
      expect(wrapper['class']).to include('md:flex-wrap')
      expect(input.parent['class']).to include('md:flex-[1_1_5rem]')
      expect(select['class']).to include('md:static')
      expect(select['class']).to include('md:w-auto')
      expect(select['class']).to include('md:max-w-full')
      expect(select['class']).to include('quantity-unit-number-field-centered-select')
      expect(select.at_css('option[selected]')&.text).to eq('セット')
    end
  end

  it '候補外の入力値も画面幅を超えないclassで再表示する' do
    invalid_unit = 'x' * 200
    document = render_quantity_unit_number_field(
      selected_unit: invalid_unit,
      unit_select_variant: :compact_suffix
    )
    select = document.at_css('select[name="quantity_unit_number_field_test_form[quantity_unit_code]"]')

    aggregate_failures do
      expect(select['class']).to include('md:max-w-full')
      expect(select.at_css('option[selected]')&.text).to eq(invalid_unit)
    end
  end

  it 'default表示の既存suffix配置は維持する' do
    document = render_quantity_unit_number_field(unit_select_variant: :default)
    select = document.at_css('select[name="quantity_unit_number_field_test_form[quantity_unit_code]"]')

    aggregate_failures do
      expect(select['class']).to include('md:absolute')
      expect(select['class']).to include('md:w-16')
      expect(select['class']).not_to include('md:w-auto')
      expect(select['class']).not_to include('quantity-unit-number-field-centered-select')
    end
  end
end
