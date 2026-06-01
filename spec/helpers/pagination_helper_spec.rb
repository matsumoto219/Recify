require 'rails_helper'

RSpec.describe PaginationHelper, type: :helper do
  PagyLike = Struct.new(:page, :last, :previous, :next, :options, keyword_init: true)

  describe '#navigation_pagination_state' do
    before do
      allow(helper).to receive(:request).and_return(double('request', query_parameters: { q: 'coffee' }))
      allow(helper).to receive(:url_for) do |params|
        query = Rack::Utils.build_query(params.except(:only_path))
        "/receipts?#{query}"
      end
    end

    it 'builds visible items and navigation urls' do
      pagy = PagyLike.new(page: 3, last: 6, previous: 2, next: 4, options: { page_key: 'page' })

      state = helper.navigation_pagination_state(pagy)

      aggregate_failures do
        expect(state).to be_render
        expect(state).to be_back_enabled
        expect(state).to be_forward_enabled
        expect(state.back_url).to eq('/receipts?q=coffee&page=2')
        expect(state.forward_url).to eq('/receipts?q=coffee&page=4')
        expect(state.items.map { |item| item.gap? ? :gap : item.page }).to eq([ 1, 2, 3, 4, :gap, 6 ])
        expect(state.items.find { |item| item.page == 3 }).to be_current
      end
    end

    it 'does not render single page pagination' do
      pagy = PagyLike.new(page: 1, last: 1, previous: nil, next: nil, options: {})

      state = helper.navigation_pagination_state(pagy)

      aggregate_failures do
        expect(state).not_to be_render
        expect(state).not_to be_back_enabled
        expect(state).not_to be_forward_enabled
      end
    end
  end
end
