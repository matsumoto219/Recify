require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get settings_index_url
    assert_response :success
  end

  test "should get account" do
    get settings_account_url
    assert_response :success
  end

  test "should get security" do
    get settings_security_url
    assert_response :success
  end
end
