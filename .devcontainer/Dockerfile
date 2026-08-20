FROM postgres:16 AS postgres_client

FROM ruby:3.3-slim

# Avoid warnings by switching to noninteractive
ENV DEBIAN_FRONTEND=noninteractive

# Install essential packages for Rails + Postgres + JS tooling + Redis
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    git-lfs \
    curl \
    ca-certificates \
    libpq-dev \
    postgresql-client \
    libyaml-dev \
    pkg-config \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Keep SQL dumps compatible with the PostgreSQL major version used by the
# database service. The base distribution may ship a newer pg_dump.
COPY --from=postgres_client /usr/lib/postgresql/16/bin/pg_dump /usr/local/bin/pg_dump

# Enable corepack for Yarn
RUN corepack enable || true

# Install bundler
RUN gem install bundler

# Create a minimal Gemfile for warming up bundle
RUN mkdir -p /tmp/warmup && \
    echo "source 'https://rubygems.org'\ngem 'rails', '~> 7.1'\ngem 'pg'\ngem 'tailwindcss-rails'" > /tmp/warmup/Gemfile && \
    cd /tmp/warmup && \
    bundle install && \
    rm -rf /tmp/warmup

# Set working directory
WORKDIR /workspace

# Switch back to dialog for any ad-hoc use of apt-get
ENV DEBIAN_FRONTEND=dialog
