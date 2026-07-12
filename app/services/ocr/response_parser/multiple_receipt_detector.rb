class Ocr::ResponseParser::MultipleReceiptDetector
  MIN_LINES = 8
  MIN_CLUSTER_RATIO = 0.2
  HORIZONTAL_GAP_RATIO = 0.08
  VERTICAL_GAP_RATIO = 0.1
  MIN_ANCHOR_LINES = 4
  MIN_ANCHOR_CATEGORIES = 4

  def self.call(pages:, profile:)
    new(pages:, profile:).call
  end

  def initialize(pages:, profile:)
    @pages = pages
    @profile = profile
  end

  def call
    Array(pages).any? do |page|
      line_boxes = receipt_line_boxes(page)
      separated_receipt_clusters?(line_boxes, page)
    end
  rescue NoMethodError, TypeError
    false
  end

  private

  attr_reader :pages, :profile

  def receipt_line_boxes(page)
    Array(page["lines"]).filter_map do |line|
      content = line["content"].to_s.strip
      box = line_polygon_box(line["polygon"])
      next if content.blank? || box.blank?

      box.merge(content: content)
    end
  end

  def line_polygon_box(polygon)
    points = Array(polygon).each_slice(2).filter_map do |x, y|
      next if x.nil? || y.nil?

      [ x.to_f, y.to_f ]
    end
    return if points.size < 4

    xs = points.map(&:first)
    ys = points.map(&:last)

    {
      min_x: xs.min,
      max_x: xs.max,
      min_y: ys.min,
      max_y: ys.max,
      center_x: xs.sum / xs.size,
      center_y: ys.sum / ys.size
    }
  end

  def separated_receipt_clusters?(line_boxes, page)
    return false if line_boxes.size < MIN_LINES * 2

    page_width = page["width"].to_f
    page_height = page["height"].to_f

    horizontal_split = horizontal_cluster_split(line_boxes, page_width)
    return true if receipt_clusters?(line_boxes, horizontal_split, axis: :x)

    vertical_split = vertical_cluster_split(line_boxes, page_height)
    receipt_clusters?(line_boxes, vertical_split, axis: :y)
  end

  def horizontal_cluster_split(line_boxes, page_width)
    return if page_width <= 0

    gap = interval_gaps(line_boxes, :min_x, :max_x).max_by { |candidate| candidate[:gap] }
    return if gap.blank?
    return if gap[:gap] < page_width * HORIZONTAL_GAP_RATIO

    (gap[:before_end] + gap[:after_start]) / 2.0
  end

  def vertical_cluster_split(line_boxes, page_height)
    return if page_height <= 0

    centers = line_boxes.map { |line| line[:center_y] }.sort
    gap = centers.each_cons(2).map { |before, after| { gap: after - before, before: before, after: after } }.max_by { |candidate| candidate[:gap] }
    return if gap.blank?
    return if gap[:gap] < page_height * VERTICAL_GAP_RATIO

    (gap[:before] + gap[:after]) / 2.0
  end

  def interval_gaps(line_boxes, min_key, max_key)
    intervals = line_boxes
      .map { |line| [ line[min_key], line[max_key] ] }
      .sort_by(&:first)

    merged = []
    intervals.each do |start_position, end_position|
      if merged.empty? || start_position > merged.last.last
        merged << [ start_position, end_position ]
      else
        merged.last[1] = [ merged.last.last, end_position ].max
      end
    end

    merged.each_cons(2).map do |before, after|
      {
        gap: after.first - before.last,
        before_end: before.last,
        after_start: after.first
      }
    end
  end

  def receipt_clusters?(line_boxes, split_position, axis:)
    return false if split_position.blank?

    center_key = axis == :x ? :center_x : :center_y
    first_cluster, second_cluster = line_boxes.partition { |line| line[center_key] < split_position }
    return false unless plausible_receipt_cluster_size?(first_cluster, line_boxes.size)
    return false unless plausible_receipt_cluster_size?(second_cluster, line_boxes.size)

    receipt_anchor_cluster?(first_cluster) && receipt_anchor_cluster?(second_cluster)
  end

  def plausible_receipt_cluster_size?(cluster, total_line_count)
    cluster.size >= MIN_LINES &&
      cluster.size >= (total_line_count * MIN_CLUSTER_RATIO)
  end

  def receipt_anchor_cluster?(cluster)
    anchor_lines = cluster.count { |line| receipt_anchor_categories(line[:content]).any? }
    categories = cluster.flat_map { |line| receipt_anchor_categories(line[:content]) }.uniq

    anchor_lines >= MIN_ANCHOR_LINES &&
      categories.size >= MIN_ANCHOR_CATEGORIES &&
      categories.include?(:date_time) &&
      (categories.include?(:total) || categories.include?(:subtotal))
  end

  def receipt_anchor_categories(content)
    text = content.to_s
    categories = []
    categories << :merchant if text.match?(profile.ocr_merchant_anchor_pattern)
    categories << :date_time if text.match?(profile.ocr_datetime_anchor_pattern)
    categories << :subtotal if text.match?(profile.ocr_subtotal_anchor_pattern)
    categories << :total if text.match?(profile.ocr_total_anchor_pattern)
    categories << :tax if text.match?(profile.ocr_tax_anchor_pattern)
    categories << :payment if text.match?(profile.ocr_payment_anchor_pattern)
    categories
  end
end
