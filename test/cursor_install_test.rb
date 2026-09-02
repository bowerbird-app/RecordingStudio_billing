# frozen_string_literal: true

require_relative "simplecov_helper"
require "fileutils"
require "json"
require "minitest/autorun"

class CursorInstallTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SANDBOX = File.expand_path("support/cursor_install_sandbox.sh", __dir__)

  def test_environment_json_points_at_tracked_executable_hooks
    env = JSON.parse(File.read(File.join(ROOT, ".cursor/environment.json")))

    assert_equal ".cursor/install.sh", env.fetch("install")
    assert_equal ".cursor/start.sh", env.fetch("start")

    %w[install start].each do |key|
      path = File.join(ROOT, env.fetch(key))
      assert File.file?(path), "#{env.fetch(key)} is missing"
      assert File.executable?(path), "#{env.fetch(key)} must be executable"
    end

    fetch = File.join(ROOT, ".cursor/fetch-skills.sh")
    assert File.file?(fetch)
    assert File.executable?(fetch)
  end

  def test_start_sh_only_starts_postgres
    start = File.read(File.join(ROOT, ".cursor/start.sh"))

    assert_includes start, "pg_ctlcluster"
    assert_includes start, "pg_isready"
    refute_includes start, "apt-get"
    refute_includes start, "ruby-build"
    refute_includes start, "fetch-skills"
    refute_includes start, "bundle"
    refute_includes start, "tailwind"
  end

  def test_install_sh_keeps_cold_provision_and_fetches_skills_last
    install = File.read(File.join(ROOT, ".cursor/install.sh"))
    fetch_at = install.rindex(%r{"\$\{SCRIPT_DIR\}/fetch-skills\.sh"})
    apt_at = install.index("apt-get")
    complete_at = install.rindex("install.sh complete")

    assert apt_at, "cold images still need apt-get"
    assert_includes install, "ruby-build"
    assert_includes install, "db:prepare"
    assert_includes install, "tailwindcss:build"
    refute_nil fetch_at, "install.sh must run fetch-skills.sh"
    assert_operator apt_at, :<, fetch_at
    assert_operator fetch_at, :<, complete_at
    refute_includes install, "fetch-skills.sh\" || true"
  end

  def test_gitignore_does_not_vendor_fetched_skills
    gitignore = File.read(File.join(ROOT, ".gitignore"))
    rules = gitignore.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("#") }

    assert_includes rules, ".cursor/skills/"
    assert_includes rules, ".cursor/rules/"
    refute_includes rules, ".cursor/install.sh"
    refute_includes rules, ".cursor/fetch-skills.sh"
    refute_includes rules, ".cursor/start.sh"
    refute_includes rules, ".cursor/environment.json"
  end

  def test_warm_machine_skips_apt_and_still_fetches_skills
    result = run_sandbox("warm")

    assert_equal 0, result.fetch("SANDBOX_EXIT"), result.fetch("stdout")
    assert_equal 1, result.fetch("SANDBOX_FETCHED"), result.fetch("log")
    assert_equal 0, result.fetch("SANDBOX_APT"), result.fetch("log")
    assert_equal 1, result.fetch("SANDBOX_SKIP"), result.fetch("stdout")
  end

  def test_failed_skippable_provision_still_fetches_skills
    result = run_sandbox("cold-apt-fail")

    assert_equal 0, result.fetch("SANDBOX_EXIT"), result.fetch("stdout")
    assert_equal 1, result.fetch("SANDBOX_FETCHED"), result.fetch("log")
    assert_equal 1, result.fetch("SANDBOX_APT"), result.fetch("log")
    assert_includes result.fetch("log"), "apt-get update"
    refute_includes result.fetch("log"), "apt-get install"
  end

  private

  def run_sandbox(mode)
    output = IO.popen(["bash", SANDBOX, mode], err: %i[child out], &:read)
    parsed = {}
    output.each_line do |line|
      key, value = line.chomp.split("=", 2)
      parsed[key] = value if key && value
    end

    %w[SANDBOX_EXIT SANDBOX_FETCHED SANDBOX_APT SANDBOX_SKIP].each do |key|
      parsed[key] = Integer(parsed.fetch(key))
    end

    parsed["stdout"] = File.read(parsed.fetch("SANDBOX_STDOUT"))
    parsed["log"] = File.read(parsed.fetch("SANDBOX_LOG"))
    FileUtils.remove_entry(parsed.fetch("SANDBOX_DIR")) if parsed["SANDBOX_DIR"] && File.directory?(parsed["SANDBOX_DIR"])
    parsed
  end
end
