require 'rails_helper'

RSpec.describe Admin::IndexHelper, type: :helper do
  Result = Struct.new(:records, :limit, :offset, :total_count, keyword_init: true)

  describe '#admin_index_pagination' do
    it 'builds pagination values and keeps aliased query params' do
      result = Result.new(records: [ :one ], limit: 1, offset: 1, total_count: 3)

      pagination = helper.admin_index_pagination(
        result,
        filters: { action: 'login', actor_kind: 'user', offset: '1' },
        parameter_aliases: { action: :audit_action }
      )

      aggregate_failures do
        expect(pagination.query_base).to eq(actor_kind: 'user', audit_action: 'login')
        expect(pagination.start_number).to eq(2)
        expect(pagination.end_number).to eq(2)
        expect(pagination.previous_offset).to eq(0)
        expect(pagination.next_offset).to eq(2)
        expect(pagination).to be_has_previous
        expect(pagination).to be_has_next
      end
    end
  end

  describe 'filter option helpers' do
    it 'builds contact request filter options from supplied values' do
      options = helper.admin_contact_request_filter_options(
        statuses: %w[open resolved],
        categories: %w[bug],
        sources: %w[manual]
      )

      aggregate_failures do
        expect(options[:statuses]).to include(
          [ I18n.t('admin.contact_requests.statuses.open'), 'open' ],
          [ I18n.t('admin.contact_requests.statuses.resolved'), 'resolved' ]
        )
        expect(options[:categories]).to eq([ [ I18n.t('admin.contact_requests.categories.bug'), 'bug' ] ])
        expect(options[:limits].map(&:last)).to eq(%w[25 50 100])
      end
    end

    it 'builds user index display options and labels' do
      options = helper.admin_user_filter_options

      aggregate_failures do
        expect(options[:booleans]).to eq([
          [ helper.t('admin.users.common.all'), '' ],
          [ helper.t('admin.users.common.yes_label'), 'true' ],
          [ helper.t('admin.users.common.no_label'), 'false' ]
        ])
        expect(options[:limits].map(&:last)).to eq(%w[25 50 100])
        expect(helper.admin_user_boolean_label(true)).to eq(helper.t('admin.users.common.yes_label'))
        expect(helper.admin_user_boolean_label(false)).to eq(helper.t('admin.users.common.no_label'))
        expect(helper.admin_short_timestamp_label(nil)).to eq('-')
      end
    end
  end
end
