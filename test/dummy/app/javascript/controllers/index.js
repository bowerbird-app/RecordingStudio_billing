import { application } from "controllers/application"
import { lazyLoadControllersFrom } from "@hotwired/stimulus-loading"

// Lazy load controllers from the host app and FlatPack engine on first use.
lazyLoadControllersFrom("controllers", application)
