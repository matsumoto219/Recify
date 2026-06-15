require 'rails_helper'

RSpec.describe SecurityEvent, type: :model do
  it '有効なsecurity eventを作成できる' do
    event = build(:security_event)

    expect(event).to be_valid
  end

  it 'event_typeをallowlistに制限する' do
    event = build(:security_event, event_type: 'unknown_attack')

    expect(event).not_to be_valid
    expect(event.errors[:event_type]).to be_present
  end

  it 'severityをallowlistに制限する' do
    event = build(:security_event, severity: 'emergency')

    expect(event).not_to be_valid
    expect(event.errors[:severity]).to be_present
  end

  it 'countは1以上に制限する' do
    event = build(:security_event, count: 0)

    expect(event).not_to be_valid
    expect(event.errors[:count]).to be_present
  end

  it 'payload excerptを上限まで切り詰める' do
    event = build(:security_event, payload_excerpt: 'a' * (described_class::PAYLOAD_EXCERPT_MAX_BYTES + 10))

    event.valid?

    expect(event.payload_excerpt.bytesize).to eq(described_class::PAYLOAD_EXCERPT_MAX_BYTES)
  end

  it 'metadataはHashだけ許可する' do
    event = build(:security_event, metadata: [ 'unsafe' ])

    expect(event).not_to be_valid
    expect(event.errors[:metadata]).to be_present
  end

  it 'metadataからsecret風keyを除去する' do
    event = build(
      :security_event,
      metadata: {
        'safe' => 'value',
        'api_key' => 'SECRET',
        'nested' => {
          'token' => 'TOKEN',
          'count' => 1
        }
      }
    )

    event.valid?

    expect(event.metadata).to eq(
      'safe' => 'value',
      'nested' => { 'count' => 1 }
    )
  end

  it 'actor_user削除後もsecurity eventを残す' do
    user = create(:user)
    event = create(:security_event, actor_user: user)

    user.destroy!

    expect(event.reload.actor_user).to be_nil
  end
end
