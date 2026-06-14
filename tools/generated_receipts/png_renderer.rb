# frozen_string_literal: true

require "fileutils"
require "base64"
require "selenium-webdriver"

module GeneratedReceipts
  class PngRenderer
    DEFAULT_WINDOW_SIZE = "900,1800"
    MACOS_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    class << self
      def call(case_data, output_path:)
        new(case_data, output_path: output_path).call
      end

      def available?
        ENV["CHROME_BIN"].to_s.strip != "" || File.exist?(MACOS_CHROME) || selenium_manager_available?
      end

      private

      def selenium_manager_available?
        Selenium::WebDriver::SeleniumManager.binary_paths("browser" => "chrome")
        true
      rescue StandardError
        false
      end
    end

    def initialize(case_data, output_path:)
      @case_data = case_data
      @output_path = output_path
    end

    def call
      raise "Chrome is not available for generated receipt PNG rendering" unless self.class.available?

      FileUtils.mkdir_p(File.dirname(output_path))
      driver = Selenium::WebDriver.for(:chrome, options: chrome_options)
      driver.navigate.to(data_url)
      wait_for_ready(driver)
      receipt = driver.find_element(css: "#receipt")
      File.binwrite(output_path, receipt.screenshot_as(:png))
      Degrader.call(case_data, image_path: output_path)
      output_path
    ensure
      driver&.quit
    end

    private

    attr_reader :case_data, :output_path

    def chrome_options
      Selenium::WebDriver::Chrome::Options.new.tap do |options|
        chrome_binary = ENV["CHROME_BIN"].to_s.strip
        chrome_binary = MACOS_CHROME if chrome_binary.empty? && File.exist?(MACOS_CHROME)
        options.binary = chrome_binary unless chrome_binary.empty?
        options.add_argument("--headless=new")
        options.add_argument("--disable-gpu")
        options.add_argument("--no-sandbox")
        options.add_argument("--hide-scrollbars")
        options.add_argument("--force-device-scale-factor=1")
        options.add_argument("--window-size=#{DEFAULT_WINDOW_SIZE}")
      end
    end

    def data_url
      "data:text/html;charset=utf-8;base64,#{Base64.strict_encode64(HtmlRenderer.call(case_data))}"
    end

    def wait_for_ready(driver)
      wait = Selenium::WebDriver::Wait.new(timeout: 5)
      wait.until { driver.execute_script("return document.readyState") == "complete" }
      driver.execute_script("return document.fonts ? document.fonts.ready : Promise.resolve()")
      sleep 0.1
    end
  end
end
