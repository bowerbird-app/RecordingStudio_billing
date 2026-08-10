class CreateFoldersAndPages < ActiveRecord::Migration[8.1]
  def change
    create_table :folders, id: :uuid do |t|
      t.string :name

      t.timestamps
    end

    create_table :pages, id: :uuid do |t|
      t.string :title

      t.timestamps
    end
  end
end
