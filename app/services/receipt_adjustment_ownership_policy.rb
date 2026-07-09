class ReceiptAdjustmentOwnershipPolicy
  NO_MATCH_PATTERN = /(?!)/.freeze

  class << self
    def bag_fee_owned_text?(text, profile:)
      text.to_s.unicode_normalize(:nfkc).match?(profile_pattern(profile, :bag_fee_owned_label_pattern))
    end

    def bag_item_owned_text?(text, profile:)
      source = text.to_s.unicode_normalize(:nfkc)
      return false if source.blank?
      return false if bag_fee_owned_text?(source, profile:)

      source.match?(profile_pattern(profile, :bag_item_owned_label_pattern))
    end

    private

    def profile_pattern(profile, name)
      if profile.respond_to?(name)
        profile.public_send(name)
      else
        NO_MATCH_PATTERN
      end
    end
  end
end
