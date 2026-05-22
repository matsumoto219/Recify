module Storage
  class AttachmentPurger
    class << self
      def call(attachment)
        new(attachment).call
      end
    end

    def initialize(attachment)
      @attachment = attachment
    end

    def call
      return false unless attachment&.attached?

      attachment.purge
      true
    end

    private

    attr_reader :attachment
  end
end
