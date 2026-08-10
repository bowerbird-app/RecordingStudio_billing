# frozen_string_literal: true

# Example migration for a Recording Studio addon.
#
# This creates a workspace-scoped table owned by the addon. Use it as a starting
# point for addon-specific data that hangs off the host application's root
# Workspace recordable.
#
class CreateGemTemplatePages < ActiveRecord::Migration[8.1]
  def change
    create_table :gem_template_pages, id: :uuid do |t|
      t.uuid :workspace_id, null: false
      t.string :title, null: false
      t.string :slug, null: false
      t.jsonb :content, default: {}, null: false
      t.boolean :published, default: false, null: false

      t.timestamps
    end

    add_page_indexes
  end

  private

  def add_page_indexes
    add_index :gem_template_pages, :workspace_id
    add_index :gem_template_pages, %i[workspace_id slug], unique: true
    add_index :gem_template_pages, :published
  end
end
