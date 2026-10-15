require 'rails_helper'
require 'tmpdir'

RSpec.describe 'Profile image storage failures', type: :request do
  self.use_transactional_tests = false

  around do |example|
    original_details = Rails.application.env_config['action_dispatch.show_detailed_exceptions']
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = false
    Dir.mktmpdir('recify-profile-storage-spec') do |directory|
      @service = ActiveStorage::Service::DiskService.new(root: directory)
      @service.name = 'test'
      example.run
    end
  ensure
    Rails.application.env_config['action_dispatch.show_detailed_exceptions'] = original_details
  end

  before do
    allow(ActiveStorage::Blob).to receive(:service).and_return(@service)
    allow(ActiveStorage::Blob.services).to receive(:fetch).with('test').and_return(@service)
    @original_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.dup
    @blob_ids = []
    @uploaded_keys = []
    @uploaded_signed_ids = []
    @user = create(:user, name: 'Before replacement')
    @user.avatar.attach(uploaded_image)
    @old_blob = @user.avatar.blob
    @old_attachment_id = @user.avatar.attachment.id
    @old_bytes = @old_blob.download
    @blob_ids << @old_blob.id
    sign_in @user
    allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
      @uploaded_keys << key
      @blob_ids << ActiveStorage::Blob.find_by!(key: key).id
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      method.call(key, io, **options)
    end
  end

  after do
    User.find_by(id: @user&.id)&.destroy!
    ActiveStorage::Blob.where(id: @blob_ids).find_each(&:purge)
    ActiveJob::Base.queue_adapter.enqueued_jobs.replace(@original_jobs) if @original_jobs
  end

  def uploaded_image
    Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/files/receipt_sample.jpg'), 'image/jpeg')
  end

  def replace_avatar(image: uploaded_image)
    patch user_registration_path, params: {
      update_context: 'account',
      user: { name: 'After replacement', avatar: image }
    }
  end

  def expect_original_avatar
    aggregate_failures do
      expect(@user.reload.name).to eq('Before replacement')
      expect(@user.avatar.attachment.id).to eq(@old_attachment_id)
      expect(@user.avatar.blob).to eq(@old_blob)
      expect(@old_blob.download).to eq(@old_bytes)
      expect(ActiveStorage::Blob.where(id: @blob_ids - [ @old_blob.id ])).to be_empty
      expect(@uploaded_keys).to all(satisfy { |key| !@service.exist?(key) })
    end
  end

  def expect_avatar_preview(blob)
    preview = Nokogiri::HTML(response.body).at_css('img[data-avatar-preview-target="image"]')
    aggregate_failures do
      expect(preview).to be_present
      expect(preview&.[]('src')).to include(blob.signed_id)
      expect(preview&.[]('data-persisted-url')).to eq(preview&.[]('src'))
      @uploaded_signed_ids.each { |signed_id| expect(response.body).not_to include(signed_id) }
    end
  end

  it '本体保存途中のI/O失敗では旧画像とプロフィールを維持する' do
    allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
      @uploaded_keys << key
      blob = ActiveStorage::Blob.find_by!(key: key)
      @blob_ids << blob.id
      @uploaded_signed_ids << blob.signed_id
      method.call(key, io, **options)
      raise Errno::ENOSPC
    end

    expect { replace_avatar }.not_to change(AuditLog, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.avatar.upload_failed'))
    expect(Nokogiri::HTML(response.body).at_css('input[name="user[name]"]')['value']).to eq('After replacement')
    expect_avatar_preview(@old_blob)
    expect_original_avatar
  end

  it '本体保存中に別の差し替えが確定した場合は競合を示し先行画像を保持する' do
    winner_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(@old_bytes), filename: 'winner.jpg', content_type: 'image/jpeg'
    )
    loser_blob = nil
    allow(@service).to receive(:upload).and_wrap_original do |method, key, io, **options|
      loser_blob = ActiveStorage::Blob.find_by!(key: key)
      @blob_ids << loser_blob.id
      @uploaded_signed_ids << loser_blob.signed_id
      method.call(key, io, **options)
      winner = User.find(@user.id)
      winner.avatar.attach(winner_blob)
      winner.update!(name: 'Concurrent winner')
    end

    expect { replace_avatar }.not_to change(AuditLog, :count)

    aggregate_failures do
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(I18n.t('activerecord.errors.models.user.attributes.avatar.stale_image'))
      expect(@user.reload.name).to eq('Concurrent winner')
      expect(@user.avatar.blob).to eq(winner_blob)
      expect(@user.avatar.download).to eq(@old_bytes)
      expect(ActiveStorage::Attachment.where(record: @user, name: 'avatar').count).to eq(1)
      expect(ActiveStorage::Blob.exists?(loser_blob.id)).to be(false)
      expect(@service.exist?(loser_blob.key)).to be(false)
    end
    expect_avatar_preview(winner_blob)
  end

  it '最終DB保存失敗では旧添付を復元し保存済みの新本体だけを破棄する' do
    allow_any_instance_of(User).to receive(:update_without_password).and_wrap_original do |method, *arguments|
      method.call(*arguments)
      raise ActiveRecord::RecordNotSaved, 'synthetic profile save failure'
    end

    replace_avatar

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).not_to include('synthetic profile save failure')
    expect(@uploaded_keys.size).to eq(1)
    expect_original_avatar
  end

  it '正常保存では新画像を1回だけ保存し旧添付だけを差し替える' do
    @user.update!(storage_limit_bytes: @old_blob.byte_size)

    expect { replace_avatar }.not_to change(AuditLog, :count)

    aggregate_failures do
      expect(response).to redirect_to(settings_path)
      expect(@user.reload.name).to eq('After replacement')
      expect(@user.avatar.blob.id).not_to eq(@old_blob.id)
      expect(@user.avatar.download).to eq(File.binread(uploaded_image.path))
      expect(@user.avatar.blob.metadata).not_to have_key('upload_preparation')
      expect(ActiveStorage::Attachment.exists?(@old_attachment_id)).to be(false)
      expect(ActiveStorage::Attachment.where(record: @user, name: 'avatar').count).to eq(1)
      expect(@uploaded_keys.size).to eq(1)
    end
  end

  it 'global容量に旧画像と新画像の両方が入らなければ旧画像を保持する' do
    allowed_bytes = ActiveStorage::Blob.sum(:byte_size) + uploaded_image.size - 1
    allow(SystemSettings).to receive(:limit_for).and_call_original
    allow(SystemSettings).to receive(:limit_for).with('storage.global_hard_stop_bytes').and_return(allowed_bytes)
    expect(@service).not_to receive(:upload)

    replace_avatar

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t('flash.storage.global_hard_stop'))
    expect_original_avatar
  end

  { '.png' => 'image/png', '.webp' => 'image/webp' }.each do |extension, content_type|
    it "#{content_type}の寸法上限超過でも旧画像を保護する" do
      allow(Receipt).to receive(:image_max_dimension).and_return(128)
      Tempfile.create([ 'synthetic-avatar', extension ]) do |file|
        file.binmode
        file.write(Vips::Image.black(129, 120, bands: 3).write_to_buffer(extension))
        file.rewind
        expect(@service).not_to receive(:upload)

        replace_avatar(image: Rack::Test::UploadedFile.new(file.path, content_type))
      end

      expect(response).to have_http_status(:unprocessable_content)
      expect_avatar_preview(@old_blob)
      expect_original_avatar
    end
  end
end
