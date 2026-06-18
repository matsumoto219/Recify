require 'rails_helper'

RSpec.describe 'Confirm dialog', type: :request do
  it 'renders one accessible shared confirm dialog in the application layout' do
    get new_user_session_path

    document = Nokogiri::HTML(response.body)
    dialog = document.at_css('dialog#confirm-dialog[data-confirm-dialog]')
    panel = dialog.at_css('.confirm-dialog-panel')
    cancel_button = dialog.at_css('button[data-confirm-dialog-cancel]')
    confirm_button = dialog.at_css('button[data-confirm-dialog-confirm]')

    aggregate_failures do
      expect(response).to have_http_status(:success)
      expect(document.css('dialog#confirm-dialog').size).to eq(1)
      expect(dialog['aria-modal']).to eq('true')
      expect(dialog['aria-labelledby']).to eq('confirm-dialog-title')
      expect(dialog['aria-describedby']).to eq('confirm-dialog-message')
      expect(dialog['data-default-backdrop']).to eq('blur')
      expect(dialog['data-confirm-backdrop']).to eq('blur')
      expect(dialog.at_css('#confirm-dialog-title')).to be_present
      expect(dialog.at_css('#confirm-dialog-message')).to be_present
      expect(panel['class']).to include('glass-panel')
      expect(cancel_button).to be_present
      expect(cancel_button['aria-label']).to eq(I18n.t('shared.confirm_dialog.cancel'))
      expect(cancel_button['class']).to include('btn-secondary')
      expect(confirm_button).to be_present
      expect(confirm_button['class']).to include('btn-primary')
      expect(dialog.to_html).not_to include('href="#"')
      expect(response.body).not_to match(/translation missing/i)
    end
  end
end
