module ApplicationHelper
  def dummy_page_nav(title:, back_url: nil, back_label: "Home")
    recording_studio_page_nav(
      title: title,
      page_nav_back_url: back_url,
      page_nav_back_label: back_label,
      page_nav_anchor_url: main_app.root_path,
      page_nav_anchor_label: "Close"
    )
  end
end
