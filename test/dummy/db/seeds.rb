# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

find_or_record_child = lambda do |recordable, root_recording, parent_recording|
  RecordingStudio::Recording.find_by(
    root_recording: root_recording,
    parent_recording: parent_recording,
    recordable: recordable,
    trashed_at: nil
  ) || RecordingStudio.record!(
    action: "created",
    recordable: recordable,
    root_recording: root_recording,
    parent_recording: parent_recording
  ).recording
end

# Create the admin user
user = User.find_or_create_by!(email: "admin@admin.com") do |u|
  u.password = "Password"
  u.password_confirmation = "Password"
end

# Create the billing roots and their capability-owned child recordables.
workspace = Workspace.find_or_create_by!(name: "Studio Workspace")
admin_root = AdminRoot.find_or_create_by!(name: "Billing Administration")
account = RecordingStudioBilling::Account.find_or_create_by!(name: "Studio Account")
billing_admin = RecordingStudioBilling::BillingAdmin.find_or_create_by!(key: "billing")

previous_actor = Current.actor
Current.actor = user

begin
  # Create the root recording
  root_recording = RecordingStudio.root_recording_for(workspace)
  admin_root_recording = RecordingStudio.root_recording_for(admin_root)

  find_or_record_child.call(account, root_recording, root_recording)
  find_or_record_child.call(billing_admin, admin_root_recording, admin_root_recording)
ensure
  Current.actor = previous_actor
end

puts "Seeded: admin@admin.com / Password"
puts "Seeded: Workspace '#{workspace.name}' with root recording ##{root_recording.id}"
puts "Seeded: Admin root '#{admin_root.name}' with root recording ##{admin_root_recording.id}"
puts "Seeded: Billing account '#{account.name}' and billing admin '#{billing_admin.key}'"
