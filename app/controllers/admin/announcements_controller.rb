class Admin::AnnouncementsController < Admin::BaseController
  LINK_FORM_ROWS = 3
  PUBLISHABLE_STATUS = "draft"
  ARCHIVABLE_STATUSES = %w[draft published].freeze

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
    result = Admin::Operations.create_announcement(
      attributes: announcement_params,
      actor: current_user,
      request: request,
      remove_image_requested: remove_image_requested?,
      uploaded_image: uploaded_announcement_image,
      security_context: announcement_security_context
    )
    @announcement = result.announcement

    if result.saved?
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
    result = Admin::Operations.update_announcement(
      announcement: @announcement,
      attributes: announcement_params,
      actor: current_user,
      request: request,
      remove_image_requested: remove_image_requested?,
      uploaded_image: uploaded_announcement_image,
      security_context: announcement_security_context
    )

    if result.saved?
      redirect_to admin_announcement_path(@announcement), notice: t("admin.announcements.messages.updated"), status: :see_other
    else
      prepare_link_rows
      render :edit, status: :unprocessable_entity
    end
  end

  def publish
    @announcement = find_announcement
    return unless ensure_reauthenticated_for_announcement!

    unless @announcement.status == PUBLISHABLE_STATUS
      redirect_to admin_announcement_path(@announcement),
                  alert: t("admin.announcements.messages.publish_not_allowed"),
                  status: :see_other
      return
    end

    result = Admin::Operations.publish_announcement(
      announcement: @announcement,
      actor: current_user,
      request: request
    )

    if result.saved?
      redirect_to admin_announcement_path(@announcement),
                  notice: t("admin.announcements.messages.published"),
                  status: :see_other
    else
      redirect_to admin_announcement_path(@announcement),
                  alert: t("admin.announcements.messages.publish_failed"),
                  status: :see_other
    end
  end

  def archive
    @announcement = find_announcement
    return unless ensure_reauthenticated_for_announcement!

    unless ARCHIVABLE_STATUSES.include?(@announcement.status)
      redirect_to admin_announcement_path(@announcement),
                  alert: t("admin.announcements.messages.archive_not_allowed"),
                  status: :see_other
      return
    end

    result = Admin::Operations.archive_announcement(
      announcement: @announcement,
      actor: current_user,
      request: request
    )

    if result.saved?
      redirect_to admin_announcement_path(@announcement),
                  notice: t("admin.announcements.messages.archived"),
                  status: :see_other
    else
      redirect_to admin_announcement_path(@announcement),
                  alert: t("admin.announcements.messages.archive_failed"),
                  status: :see_other
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
      :image,
      :image_alt_text,
      :remove_image,
      :kind,
      :pinned,
      :priority,
      :starts_at,
      :ends_at,
      announcement_links_attributes: %i[id label url position _destroy]
    ).to_h
    permitted.delete("remove_image")
    permitted.delete("image_alt_text") if remove_image_requested? && uploaded_announcement_image.blank?

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

  def ensure_reauthenticated_for_announcement!
    return true if admin_passkey_reauthenticated?

    redirect_to new_admin_passkey_reauthentication_path(return_to: admin_announcement_path(@announcement)),
                alert: t("admin.passkey_reauthentications.messages.required"),
                status: :see_other
    false
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

  def remove_image_requested?
    ActiveModel::Type::Boolean.new.cast(params.dig(:announcement, :remove_image))
  end

  def uploaded_announcement_image
    params.dig(:announcement, :image)
  end

  def announcement_security_context
    {
      controller: controller_path,
      action: action_name
    }
  end

  def raise_not_found
    raise ActionController::RoutingError,
          "No route matches [#{request.request_method}] #{request.path}"
  end
end
