require 'rails_helper'

RSpec.describe ApplicationHelper, type: :helper do
  describe '#confirm_dialog_data' do
    it 'builds default confirm dialog data from only a message' do
      data = helper.confirm_dialog_data('Are you sure?')

      aggregate_failures do
        expect(data).to eq(
          turbo_confirm: 'Are you sure?',
          confirm_variant: 'neutral',
          confirm_icon: 'help'
        )
      end
    end

    it 'keeps optional values allowlisted' do
      data = helper.confirm_dialog_data(
        'Delete this receipt?',
        variant: :danger,
        icon: :delete,
        confirm_label: 'Delete',
        title: 'Confirm deletion',
        backdrop: :plain
      )

      aggregate_failures do
        expect(data).to include(
          turbo_confirm: 'Delete this receipt?',
          confirm_variant: 'danger',
          confirm_icon: 'delete',
          confirm_confirm_label: 'Delete',
          confirm_title: 'Confirm deletion',
          confirm_backdrop: 'plain'
        )
        expect(data).not_to have_key(:confirm_surface)
      end
    end

    it 'falls back when option values are not allowed' do
      data = helper.confirm_dialog_data(
        'Run action?',
        variant: :unknown,
        icon: :unknown,
        backdrop: :unknown
      )

      aggregate_failures do
        expect(data).to eq(
          turbo_confirm: 'Run action?',
          confirm_variant: 'neutral',
          confirm_icon: 'help'
        )
      end
    end
  end
end
