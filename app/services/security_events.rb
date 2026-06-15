module SecurityEvents
  class << self
    def detect(...)
      Detector.call(...)
    end

    def record!(...)
      Recorder.call(...)
    end
  end
end
