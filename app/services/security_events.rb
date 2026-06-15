module SecurityEvents
  class << self
    def record!(...)
      Recorder.call(...)
    end
  end
end
