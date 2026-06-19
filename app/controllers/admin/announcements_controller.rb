class Admin::AnnouncementsController < Admin::BaseController
  LINK_FORM_ROWS = 3

  def index
    @filters = filter_params
    @result = Admin.announcements(**@filters)
    @filter_options = Admin.announcement_filter_options
  end

  def show
    @announcement = find_announcement
    prepare_link_rows
  end

  def new
    @announcement = Announcement.new(status: "draft", kind: "general", priority: 0)
    prepare_link_rows
  end

  def create
    @announcement = Announcement.new(announcement_params)
    @announcement.status = "draft"
    @announcement.created_by = current_user
    @announcement.updated_by = current_user

    if @announcement.save
      redirect_to admin_announcement_path(@announcement), notice: t("admin.announcements.messages.created"), status: :see_other
    else
      prepare_link_rows
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @announcement = find_announcement
    ensure_draft_editable!
    prepare_link_rows
  end

  def update
    @announcement = find_announcement
    ensure_draft_editable!
    @announcement.assign_attributes(announcement_params)
    @announcement.status = "draft"
    @announcement.updated_by = current_user

    if @announcement.save
      redirect_to admin_announcement_path(@announcement), notice: t("admin.announcements.messages.updated"), status: :see_other
    else
      prepare_link_rows
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def filter_params
    params.permit(
      :status,
      :kind,
      :pinned,
      :public_id,
      :title,
      :starts_at_from,
      :starts_at_to,
      :ends_at_from,
      :ends_at_to,
      :published_at_from,
      :published_at_to,
      :limit,
      :offset
    ).to_h.each_with_object({}) do |(key, value), filters|
      filters[key.to_sym] = value if value.present?
    end
  end

  def announcement_params
    permitted = params.require(:announcement).permit(
      :title,
      :body,
      :kind,
      :pinned,
      :priority,
      :starts_at,
      :ends_at,
      announcement_links_attributes: %i[id label url position _destroy]
    ).to_h

    permitted["announcement_links_attributes"] = normalized_link_attributes(
      permitted["announcement_links_attributes"]
    )
    permitted
  end

  def normalized_link_attributes(attributes)
    Array(attributes&.to_h&.sort_by { |index, _row| index.to_i })
      .first(LINK_FORM_ROWS)
      .each_with_index
      .to_h do |(_index, row), position|
        row = row.to_h
        label = row["label"].to_s.strip
        url = row["url"].to_s.strip
        id = row["id"].presence
        link_attributes = { "id" => id, "label" => label, "url" => url, "position" => position }.compact
        link_attributes["_destroy"] = "1" if id.present? && label.blank? && url.blank?

        [ position.to_s, link_attributes ]
      end
  end

  def find_announcement
    Announcement.includes(:announcement_links, :created_by, :updated_by).find_by!(public_id: params[:id])
  rescue ActiveRecord::RecordNotFound
    raise_not_found
  end

  def ensure_draft_editable!
    return if @announcement.status == "draft"

    raise_not_found
  end

  def prepare_link_rows
    links_by_position = @announcement
      .announcement_links
      .reject(&:marked_for_destruction?)
      .sort_by(&:position)
      .index_by(&:position)
    @announcement_link_rows = Array.new(LINK_FORM_ROWS) do |index|
      links_by_position[index] || AnnouncementLink.new(position: index)
    end
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
