# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# Create the admin user
user = User.find_or_create_by!(email: "admin@admin.com") do |u|
  u.password = "Password"
  u.password_confirmation = "Password"
end

# Create the billing roots and their capability-owned child recordables.
workspace = Workspace.find_or_create_by!(name: "Studio Workspace")
admin_root = AdminRoot.find_or_create_by!(name: "Billing Administration")
previous_actor = Current.actor
Current.actor = user

begin
  # Create the root recording
  root_recording = RecordingStudio.root_recording_for(workspace)
  admin_root_recording = RecordingStudio.root_recording_for(admin_root)

  account = RecordingStudioBilling.ensure_account(root_recording: root_recording, name: "Studio Account")
  billing_admin = RecordingStudioBilling.ensure_billing_admin(
    root_recording: admin_root_recording,
    key: "billing"
  )
ensure
  Current.actor = previous_actor
end

puts "Seeded: admin@admin.com / Password"
puts "Seeded: Workspace '#{workspace.name}' with root recording ##{root_recording.id}"
puts "Seeded: Admin root '#{admin_root.name}' with root recording ##{admin_root_recording.id}"
puts "Seeded: Billing account '#{account.name}' and billing admin '#{billing_admin.key}'"
