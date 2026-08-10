class CreateWorkspaces < ActiveRecord::Migration[8.1]
  def change
    create_table :workspaces, id: :uuid do |t|
      t.string :name

      t.timestamps
    end
  end
end
