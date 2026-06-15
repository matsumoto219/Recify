require 'rails_helper'

RSpec.describe 'Security events', type: :request do
  let(:user) { create(:user) }

  before do
    sign_in user
  end

  it '通常リクエストではsecurity eventを作成しない' do
    expect {
      get receipts_path
    }.not_to change(SecurityEvent, :count)
  end

  it '危険なparamsをsafe excerpt付きsecurity eventとして記録する' do
    expect {
      get receipts_path, params: { q: '<script>alert(1)</script>' }
    }.to change(SecurityEvent, :count).by(1)

    event = SecurityEvent.last
    expect(event).to have_attributes(
      event_type: 'xss_attempt',
      severity: 'high',
      actor_user: user,
      field_name: 'q',
      payload_excerpt: '<script>alert(1)</script>'
    )
  end

  it 'invalid uploadをfile bodyなしで記録する' do
    invalid_file = Tempfile.new([ 'fake-receipt', '.jpg' ])
    invalid_file.write('not an image')
    invalid_file.rewind

    expect {
      post upload_receipts_path,
           params: {
             receipt: {
               image: Rack::Test::UploadedFile.new(invalid_file.path, 'image/jpeg')
             }
           }
    }.to change(SecurityEvent.where(event_type: 'invalid_upload'), :count).by(1)

    event = SecurityEvent.last
    expect(event.metadata).to include(
      'content_type' => 'image/jpeg',
      'reason' => 'invalid_content_type'
    )
    expect(event.metadata.to_json).not_to include('not an image')
  ensure
    invalid_file&.close
    invalid_file&.unlink
  end

  it '403をIDOR候補として記録する' do
    expect {
      get '/403'
    }.to change(SecurityEvent.where(event_type: 'idor_attempt'), :count).by(1)

    expect(SecurityEvent.last).to have_attributes(
      severity: 'high',
      matched_rule: 'suspicious_403'
    )
  end
end
