module NotificationsHelper
  NotificationItemState = Struct.new(
    :unread,
    :stale_notifiable,
    :read_path,
    :delete_confirm_data,
    :icon,
    :icon_class,
    :item_classes,
    :action_available,
    :action_path,
    keyword_init: true
  ) do
    def unread?
      unread == true
    end

    def stale_notifiable?
      stale_notifiable == true
    end

    def action_available?
      action_available == true
    end
  end

  def notification_dropdown_item_state(notification)
    notification_item_state(notification, variant: :dropdown)
  end

  def notification_list_item_state(notification)
    notification_item_state(notification, variant: :list)
  end

  private

  def notification_item_state(notification, variant:)
    unread = notification.unread?
    icon_config = notification_icon_config(notification.kind)

    NotificationItemState.new(
      unread: unread,
      stale_notifiable: notification.stale_notifiable?,
      read_path: read_notification_path(notification),
      delete_confirm_data: notification_delete_confirm_data(notification),
      icon: icon_config[:icon],
      icon_class: icon_config[:class],
      item_classes: notification_item_classes(variant:, unread: unread),
      action_available: notification.action_available?,
      action_path: notification.action_path
    )
  end

  def notification_delete_confirm_data(notification)
    return {} unless notification.user.delete_confirmation_enabled?

    { turbo_confirm: t("notifications.item.delete_confirm") }
  end

  def notification_icon_config(kind)
    case kind
    when "receipt_completed"
      { icon: "check_circle", class: "token-state-success-soft" }
    when "receipt_review_needed"
      { icon: "warning", class: "token-state-warning-soft" }
    when "receipt_failed"
      { icon: "error", class: "token-state-error-soft" }
    else
      { icon: "notifications", class: "notice-icon-info" }
    end
  end

  def notification_item_classes(variant:, unread:)
    case variant
    when :dropdown
      [
        "flex items-start gap-2 border-b token-border-glass px-4 py-3 text-left transition-colors token-hover-bg-card-subtle",
        unread ? "token-brand-soft-bg" : nil
      ].compact.join(" ")
    else
      [
        "token-bg-card",
        "token-border-soft",
        "rounded-lg border p-4 transition-colors",
        ("token-brand-soft-bg" if unread)
      ].compact.join(" ")
    end
  end
end
