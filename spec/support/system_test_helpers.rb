require "webmock/rspec"

module SystemTestHelpers
  SYSTEM_TEST_ENV = {
    "RECEIPT_OCR_ENABLED" => "false",
    "RECEIPT_AI_ENABLED" => "false",
    "TURNSTILE_ENABLED" => "false"
  }.freeze

  DEFAULT_SCREEN_SIZE = [ 1440, 1000 ].freeze
  MOBILE_SCREEN_SIZE = [ 390, 844 ].freeze

  def create_system_test_user(**attributes)
    LegalDocuments::Sync.call
    user = create(:user, **attributes)
    LegalAcceptances::Recorder.record_current_documents!(
      user: user,
      acceptance_context: "signup",
      request: nil,
      locale: :ja
    )
    user
  end

  def wait_for_stimulus_controller(identifier)
    connected = page.evaluate_async_script(<<~JAVASCRIPT, identifier, Capybara.default_max_wait_time * 1000)
      const identifier = arguments[0]
      const timeoutMilliseconds = arguments[1]
      const done = arguments[arguments.length - 1]
      const deadline = window.performance.now() + timeoutMilliseconds

      const check = () => {
        const controllers = window.Stimulus?.controllers || []
        if (controllers.some((controller) => controller.identifier === identifier)) {
          done(true)
          return
        }

        if (window.performance.now() >= deadline) {
          done(false)
          return
        }

        window.setTimeout(check, 25)
      }

      check()
    JAVASCRIPT

    expect(connected).to be(true), "Stimulus controller did not connect: #{identifier}"
  end

  def expect_browser_console_clean
    unexpected_entries = browser_console_entries.select do |entry|
      entry.level == "SEVERE" && !blocked_external_font_entry?(entry)
    end

    messages = unexpected_entries.map { |entry| "[#{entry.level}] #{entry.message}" }
    expect(unexpected_entries).to be_empty, <<~MESSAGE
      Unexpected browser console entries:
      #{messages.join("\n")}
    MESSAGE
  end

  private

  def browser_console_entries
    page.driver.browser.logs.get(:browser)
  rescue Selenium::WebDriver::Error::UnsupportedOperationError => error
    raise "Browser console logging is unavailable: #{error.message}"
  end

  def blocked_external_font_entry?(entry)
    entry.message.match?(%r{https://fonts\.(?:googleapis|gstatic)\.com/}) &&
      entry.message.include?("ERR_NAME_NOT_RESOLVED")
  end
end

Capybara.default_max_wait_time = 5
Capybara.enable_aria_label = true
Capybara.save_path = Rails.root.join("tmp/screenshots").to_s

RSpec.configure do |config|
  config.include SystemTestHelpers, type: :system

  config.before(type: :system) do |example|
    screen_size = example.metadata[:screen_size]
    screen_size = SystemTestHelpers::MOBILE_SCREEN_SIZE if example.metadata[:mobile]
    screen_size ||= SystemTestHelpers::DEFAULT_SCREEN_SIZE
    browser = ENV["SYSTEM_TEST_HEADLESS"] == "0" ? :chrome : :headless_chrome

    driven_by :selenium, using: browser, screen_size: screen_size do |options|
      options.add_argument("--disable-background-networking")
      options.add_argument("--disable-dev-shm-usage") if ENV["CI"].present?
      options.add_argument(
        "--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1"
      )
      options.add_option("goog:loggingPrefs", { browser: "ALL" })
    end
  end

  config.before(type: :system) do
    page.driver.browser.logs.get(:browser)
  rescue Selenium::WebDriver::Error::UnsupportedOperationError
    nil
  end

  config.around(type: :system) do |example|
    original_env = SystemTestHelpers::SYSTEM_TEST_ENV.to_h do |key, _value|
      [ key, [ ENV.key?(key), ENV[key] ] ]
    end
    SystemTestHelpers::SYSTEM_TEST_ENV.each { |key, value| ENV[key] = value }
    WebMock.disable_net_connect!(allow_localhost: true)
    example.run
  ensure
    original_env.each do |key, (present, value)|
      present ? ENV[key] = value : ENV.delete(key)
    end
    WebMock.allow_net_connect!
  end

  config.after(type: :system) do |example|
    allowed_patterns = Array(example.metadata[:allowed_browser_console_failures])
    unexpected_entries = page.driver.browser.logs.get(:browser).select do |entry|
      entry.level == "SEVERE" &&
        !blocked_external_font_entry?(entry) &&
        allowed_patterns.none? { |pattern| entry.message.match?(pattern) }
    end
    messages = unexpected_entries.map { |entry| "[#{entry.level}] #{entry.message}" }

    expect(unexpected_entries).to be_empty, <<~MESSAGE
      Unasserted browser console entries:
      #{messages.join("\n")}
    MESSAGE
  rescue Selenium::WebDriver::Error::UnsupportedOperationError
    nil
  end
end
