ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def sign_in_with_current_legal_acceptance(resource, scope: nil)
    accept_current_legal_documents_for_test(resource)
    sign_in(resource, scope: scope)
  end

  private

  def accept_current_legal_documents_for_test(resource)
    return unless resource.is_a?(User)
    return unless resource.persisted?
    return if resource.guest?

    LegalDocuments::Sync.call
    LegalAcceptances::Recorder.record_current_documents!(
      user: resource,
      acceptance_context: "signup",
      request: nil,
      locale: :ja
    )
  end
end
