# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# Pin FlatPack controllers
pin_all_from FlatPack::Engine.root.join("app/javascript/flat_pack/controllers"), under: "controllers/flat_pack", to: "flat_pack/controllers", preload: false
pin "flat_pack/heroicons", to: "flat_pack/heroicons.js", preload: false
