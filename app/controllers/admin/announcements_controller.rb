class Admin::AnnouncementsController < Admin::BaseController
  LINK_FORM_ROWS = 3
  PUBLISHABLE_STATUS = "draft"
  ARCHIVABLE_STATUSES = %w[draft published].freeze
  AUDIT_LINK_LIMIT = 3

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

  def publish
    @announcement = find_announcement
    return unless ensure_reauthenticated_for_announcement!

    unless @announcement.status == PUBLISHABLE_STATUS
      redirect_to admin_announcement_path(@announcement),
                  alert: t("admin.announcements.messages.publish_not_allowed"),
                  status: :see_other
      return
    end

    before_status = @announcement.status
    @announcement.status = "published"
    @announcement.published_at ||= Time.current
    @announcement.updated_by = current_user

    if @announcement.save
      record_announcement_audit!(
        action: "announcement.publish",
        before_status: before_status,
        after_status: @announcement.status
      )
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

    before_status = @announcement.status
    @announcement.status = "archived"
    @announcement.updated_by = current_user

    if @announcement.save
      record_announcement_audit!(
        action: "announcement.archive",
        before_status: before_status,
        after_status: @announcement.status
      )
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

  def ensure_reauthenticated_for_announcement!
    return true if admin_passkey_reauthenticated?

    redirect_to new_admin_passkey_reauthentication_path(return_to: admin_announcement_path(@announcement)),
                alert: t("admin.passkey_reauthentications.messages.required"),
                status: :see_other
    false
  end

  def record_announcement_audit!(action:, before_status:, after_status:)
    AuditLogs.record_admin_action!(
      actor: current_user,
      action: action,
      target: @announcement,
      target_uid: @announcement.public_id,
      outcome: "succeeded",
      request: request,
      metadata: announcement_audit_metadata,
      before_state: { status: before_status },
      after_state: {
        status: after_status,
        published_at: @announcement.published_at
      }
    )
  end

  def announcement_audit_metadata
    {
      public_id: @announcement.public_id,
      title: @announcement.title,
      kind: @announcement.kind,
      starts_at: @announcement.starts_at,
      ends_at: @announcement.ends_at,
      pinned: @announcement.pinned,
      priority: @announcement.priority,
      published_at: @announcement.published_at,
      links: announcement_audit_links
    }
  end

  def announcement_audit_links
    @announcement.announcement_links.sort_by(&:position).first(AUDIT_LINK_LIMIT).map do |link|
      {
        position: link.position,
        label: link.label,
        external: link.external?,
        url: sanitized_audit_url(link.url)
      }
    end
  end

  def sanitized_audit_url(value)
    url = value.to_s
    uri = URI.parse(url)

    if url.start_with?("/")
      uri.path.presence || "/"
    else
      port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
      path = uri.path.presence || "/"
      "#{uri.scheme}://#{uri.host}#{port}#{path}"
    end
  rescue URI::InvalidURIError
    "[invalid]"
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
