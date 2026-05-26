class AuditLog < ApplicationRecord
  ACTOR_KINDS = %w[admin system].freeze
  OUTCOMES = %w[succeeded failed].freeze

  # Audit logs are append-only operational records. Update existing rows only
  # via a migration/backfill with an explicit reason.
  belongs_to :actor_user,
             class_name: "User",
             optional: true

  validates :actor_kind, presence: true, inclusion: { in: ACTOR_KINDS }
  validates :action, presence: true
  validates :outcome, presence: true, inclusion: { in: OUTCOMES }
  validate :json_fields_are_hashes

  private

  def json_fields_are_hashes
    %i[metadata before_state after_state].each do |attribute|
      value = public_send(attribute)
      errors.add(attribute, :invalid) unless value.is_a?(Hash)
    end
  end
end
