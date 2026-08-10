# Private Gem Dependencies (Deprecated)

**⚠️ This documentation is deprecated as of February 2025.**

This gem template **no longer depends on private Ruby gems**. All dependencies are now public gems available on RubyGems.org or public GitHub repositories.

For historical reference, this document previously explained how to authenticate with private GitHub repositories. That authentication is no longer required for this template.

## Current Dependencies

All gem dependencies for this template are now:
- Available on RubyGems.org, or
- Hosted as public GitHub repositories

No special authentication or access tokens are needed.

## GitHub Codespaces

**No configuration required.** All dependencies install automatically.

The `postCreateCommand` in `.devcontainer/devcontainer.json` handles gem installation automatically.

## Local Development

Simply run:

```bash
bundle install
```

No GitHub Personal Access Token or special configuration is needed.

## Production Deployment

Standard bundler installation works:

```bash
bundle install
```

No authentication tokens required.

## Migrating from Private Gems

If you previously used private gems in your fork of this template:

1. Remove any private gem references from your `Gemfile`
2. Remove any authentication tokens from your environment
3. Use public alternatives:
   - For UI components: Use `flat_pack` gem instead of `makeup_artist`
   - Other private dependencies should be replaced with public alternatives

## Security Best Practices

- **Never commit tokens** to version control
- Remove any unused authentication tokens from your environment
- If you add private dependencies to your fork, use Codespaces secrets or environment variables

## Troubleshooting

If `bundle install` fails, ensure:
- You have an active internet connection
- You're using a supported Ruby version (see `.ruby-version`)
- Your `Gemfile.lock` is up to date

Need help? Check the internal Bowerbird docs or ask in `#engineering`.
