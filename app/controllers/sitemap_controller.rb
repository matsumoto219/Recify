# frozen_string_literal: true

class SitemapController < ApplicationController
  layout false

  def show
    @static_paths = [
      root_path,
      terms_path,
      privacy_path
    ]

    respond_to do |format|
      format.xml
    end
  end
end
