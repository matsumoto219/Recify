require 'rails_helper'

RSpec.describe ContactRequestsHelper, type: :helper do
  describe '#contact_request_category_options' do
    it 'builds localized category options from the ContactRequests entrypoint' do
      options = helper.contact_request_category_options(%w[bug account])

      expect(options).to eq([
        [ I18n.t('contact_requests.categories.bug'), 'bug' ],
        [ I18n.t('contact_requests.categories.account'), 'account' ]
      ])
    end
  end
end
