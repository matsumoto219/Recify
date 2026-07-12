require Rails.root.join("lib/recify/active_storage_purge_fallback").to_s

Rails.application.config.to_prepare do
  unless ActiveStorage::Blob < Recify::ActiveStoragePurgeFallback
    ActiveStorage::Blob.prepend(Recify::ActiveStoragePurgeFallback)
  end
end
