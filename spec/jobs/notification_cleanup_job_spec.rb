require 'rails_helper'

RSpec.describe NotificationCleanupJob, type: :job do
  it '古い通知cleanupを実行する' do
    expect(Notification).to receive(:cleanup_old!)

    described_class.perform_now
  end
end
