===============================================================================

RecordingStudioBilling has been installed successfully!

The engine has been mounted at /recording_studio_billing in your application.
Active Record must use SQL schema format. Commit db/structure.sql so the
PostgreSQL functions and triggers that protect billing history are preserved.

If you use Tailwind CSS:
1. Run 'bin/rails tailwindcss:build' to rebuild your CSS with RecordingStudioBilling styles

To use the engine:
1. Start your Rails server
2. Visit http://localhost:3000/recording_studio_billing

To use the Billing Admin hub, add these routes in this order:

    draw_recording_studio_billing_admin
    recording_studio_admin_for :admin, at: "/admin", root_section: :billing

===============================================================================
