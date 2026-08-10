> **Architecture Documentation**
> *   **Canonical Source:** [bowerbird-app/gem_template](https://github.com/bowerbird-app/gem_template/tree/main/docs/gem_template)
> *   **Last Updated:** December 11, 2025
>
> *Maintainers: Please update the date above when modifying this file.*

---

Rails Engine Architecture: Providing CSS and JavaScript Assets to Host Applications

This document outlines the recommended architecture for Rails engines that supply CSS (e.g., Tailwind v4) and JavaScript (e.g., Stimulus or ES modules) to a host Rails application or another Rails engine. This approach supports both modern Rails apps using Propshaft (default) and legacy Rails apps still using Sprockets.

------------------------------------------------------------
1. CSS Architecture (Tailwind CSS v4)
------------------------------------------------------------

Rails engines should ship raw Tailwind CSS inputs, not precompiled CSS.
The host application's Tailwind build process generates the final stylesheet.

------------------------------------------------------------
1.1 How Tailwind Sees Files Inside an Engine
------------------------------------------------------------

Modify the host app’s Tailwind entry file:

    app/assets/tailwind/application.css

Add scan directives:

    @source "/path/to/gems/my_engine/app/views/**/*.erb";
    @source "/path/to/gems/my_engine/app/components/**/*.html.erb";

------------------------------------------------------------
1.2 Theme Integration (CSS Variables / Tokens)
------------------------------------------------------------

Engines may provide design tokens (colors, spacing, radii, etc.).

The install generator should:

1. Copy:
       config/my_engine/ui_theme.css

2. Add to Tailwind entrypoint:

       @import "../../config/my_engine/ui_theme.css";

------------------------------------------------------------
1.3 Where CSS Imports Must Be Added
------------------------------------------------------------

### Installing into a Rails application

Modify:

    app/assets/tailwind/application.css

Add:

    @import "../../config/my_engine/ui_theme.css";
    @source "/path/to/gems/my_engine/app/views/**/*.erb";

### Installing into another Rails engine

If Tailwind files do not exist, the installer must create:

    app/assets/tailwind/application.css

with base Tailwind setup, theme import, and @source directives.

------------------------------------------------------------
2. JavaScript Architecture (Importmap + Propshaft)
------------------------------------------------------------

Default for modern Rails apps. Uses:
- Propshaft for asset serving
- Importmap for module resolution

------------------------------------------------------------
2.1 Propshaft Integration
------------------------------------------------------------

In engine.rb:

    initializer "<engine_name>.assets.precompile" do |app|
      app.config.assets.paths << root.join("app/javascript")
    end

------------------------------------------------------------
2.2 Importmap Integration
------------------------------------------------------------

In engine.rb:

    initializer "<engine_name>.importmap", before: "importmap" do |app|
      app.config.importmap.paths << root.join("config/importmap.rb")
    end

In config/importmap.rb:

    pin "<engine_name>", to: "<engine_name>/index.js"
    pin_all_from "<engine_name>/controllers", under: "<engine_name>/controllers"

------------------------------------------------------------
2.3 Where JS Imports Must Be Added
------------------------------------------------------------

### Installing into a Rails application

Modify:

    app/javascript/application.js

Add:

    import "<engine_name>";

If using Stimulus:

    app/javascript/controllers/index.js

### Installing into another Rails engine

If missing, the installer should create:
- app/javascript/application.js
- config/importmap.rb
- app/javascript/controllers/index.js

------------------------------------------------------------
3. Install Generator Responsibilities
------------------------------------------------------------

The installer must:

- Modify or create app/assets/tailwind/application.css
- Modify or create app/javascript/application.js
- Modify or create config/importmap.rb
- Modify or create app/javascript/controllers/index.js
- Copy theme tokens to config/<engine_name>/
- Create config/initializers/<engine_name>.rb
- Avoid duplicate insertions
- Detect whether host uses Propshaft or Sprockets

------------------------------------------------------------
4. Legacy Support: Installing into Sprockets Apps
------------------------------------------------------------

By default use Propshaft; this section explains how to support Sprockets.

------------------------------------------------------------
4.1 Key Differences
------------------------------------------------------------

Propshaft (default):
- Uses app/javascript/application.js
- Uses Importmap
- Tailwind via @source
- No manifest files

Sprockets (legacy):
- Uses app/assets/stylesheets/application.css
- Uses app/assets/javascripts/application.js
- Includes engine assets using *= require and //= require
- Runs rails assets:precompile
- Typically no Importmap

------------------------------------------------------------
4.2 CSS with Sprockets
------------------------------------------------------------

Add to:

    app/assets/stylesheets/application.css

Include engine CSS:

    /*
     *= require my_engine/application
     */

If using Tailwind CLI, engine installs Tailwind source and modifies the build entrypoint accordingly.

------------------------------------------------------------
4.3 JS with Sprockets
------------------------------------------------------------

Modify:

    app/assets/javascripts/application.js

Add:

    //= require my_engine/application

Sprockets hosts do NOT require:

- config/importmap.rb
- app/javascript/application.js

------------------------------------------------------------
4.4 File Detection Logic
------------------------------------------------------------

Propshaft (preferred) detected if:

    config/importmap.rb
    app/javascript/application.js
    app/assets/tailwind/application.css

Sprockets detected if:

    app/assets/javascripts/application.js
    app/assets/stylesheets/application.css
    config/initializers/assets.rb

The installer defaults to Propshaft and falls back to Sprockets when detected.

------------------------------------------------------------
Why This Architecture Works
------------------------------------------------------------

- Works for modern and legacy Rails asset pipelines
- Engines remain clean and modular
- Host controls the theme and build process
- Tailwind integrates reliably in both pipelines
- Avoids bundlers by default

------------------------------------------------------------
5. Reference Implementation: The Dummy App
------------------------------------------------------------

The `test/dummy` application serves as both a test harness and a reference implementation for how the engine's assets should be integrated.

------------------------------------------------------------
5.1 Directory Structure
------------------------------------------------------------

```
test/dummy/
├── app/assets/
│   ├── builds/
│   │   └── tailwind.css          # Compiled output (auto-generated)
│   ├── stylesheets/
│   │   └── application.css       # Standard Rails stylesheet
│   └── tailwind/
│       └── application.css       # Tailwind source file (entry point)
└── ...
```

------------------------------------------------------------
5.2 Tailwind Entry Point
------------------------------------------------------------

The file `test/dummy/app/assets/tailwind/application.css` configures Tailwind:

```css
@import "tailwindcss";

/* Include the engine's views in the Tailwind build */
@source "../../../../../app/views/**/*.erb";
```

> **Note:** The relative path `../../../../../app/views/**/*.erb` points from the dummy app up to the engine's `app/views` folder so Tailwind can detect classes used in engine templates. Host applications will use the gem path instead.

------------------------------------------------------------
5.3 Auto-Rebuild in Development
------------------------------------------------------------

The dummy app uses `foreman` to run the Rails server and the Tailwind watcher concurrently.

**Procfile.dev** (`test/dummy/Procfile.dev`):

```
web: bin/rails server -b 0.0.0.0
css: bin/rails tailwindcss:watch
```

**bin/dev** (`test/dummy/bin/dev`):

This script installs foreman if missing and starts the processes defined in `Procfile.dev`.

To run the development environment:

```bash
cd test/dummy
bin/dev
```

------------------------------------------------------------
5.4 Manual Build Commands
------------------------------------------------------------

| Command                           | Description                                  |
|-----------------------------------|----------------------------------------------|
| `bin/rails tailwindcss:build`     | One-time build of Tailwind CSS.              |
| `bin/rails tailwindcss:watch`     | Watch mode; rebuilds on file changes.        |
| `bin/rails tailwindcss:clobber`   | Deletes compiled CSS in `app/assets/builds`. |
