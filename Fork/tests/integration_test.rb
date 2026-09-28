require 'minitest/autorun'
require 'yaml'
require 'open3'
require 'tmpdir'
require 'fileutils'
require 'shellwords'

class ForkIntegrationTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  TAG = 'v3.0.18-statscompact.123456'
  SHA = 'a' * 40

  def workflow(name)
    YAML.safe_load(File.read(File.join(ROOT, '.github/workflows', name)))
  end

  def test_weekly_and_manual_builds_share_the_same_publisher
    weekly = workflow('sync-upstream.yaml')
    build = workflow('fork-build.yaml')
    triggers = build['on'] || build[true] # Psych's YAML 1.1 treats "on" as a boolean.
    assert_equal './.github/workflows/fork-build.yaml', weekly['jobs']['build-and-release']['uses']
    assert_equal true, weekly['jobs']['build-and-release']['with']['publish_release']
    %w[workflow_call workflow_dispatch].each do |event|
      assert_equal 'boolean', triggers[event]['inputs']['publish_release']['type']
    end
    assert_equal ['master'], triggers['push']['branches']
    steps = build['jobs']['build']['steps'].map { |step| step['name'] }
    assert_operator steps.index('Validate auto-update bundle'), :<, steps.index('Publish public release')
    assert_operator steps.index('Package application'), :<, steps.index('Publish public release')
  end

  def test_upstream_build_cannot_duplicate_or_cancel_the_fork_build
    upstream = workflow('build.yaml')
    fork = workflow('fork-build.yaml')
    assert_equal "github.repository == 'exelban/stats'", upstream['jobs']['build']['if']
    assert_equal "github.repository == 'tovam/stats-macos'", fork['jobs']['build']['if']
    refute_equal upstream['concurrency']['group'], fork['concurrency']['group']
  end

  def with_bundle(overrides = {})
    # All fixture files are generated under the project. No installed app,
    # preferences, caches, Keychain or home directory is accessed.
    Dir.mktmpdir('.codex-fork-test-', ROOT) do |fixture_root|
      app = File.join(fixture_root, 'Stats Compact.app')
      scripts = File.join(app, 'Contents/Resources/Scripts')
      FileUtils.mkdir_p(scripts)
      values = {
        'CFBundleIdentifier' => 'com.tovam.StatsCompact',
        'CFBundleExecutable' => 'Stats Compact',
        'CompactReleaseRepository' => 'tovam/stats-macos',
        'CompactReleaseTag' => TAG,
        'CompactBuildSHA' => SHA
      }.merge(overrides)
      entries = values.map { |key, value| "<key>#{key}</key><string>#{value}</string>" }.join
      File.write(File.join(app, 'Contents/Info.plist'), "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>#{entries}</dict></plist>")
      FileUtils.mkdir_p(File.join(app, 'Contents/MacOS'))
      executable = File.join(app, 'Contents/MacOS/Stats Compact')
      File.write(executable, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, executable)
      FileUtils.cp(File.join(ROOT, 'Kit/scripts/updater.sh'), File.join(scripts, 'updater.sh'))
      FileUtils.cp(File.join(ROOT, 'Kit/scripts/compact/uninstall.sh'), File.join(scripts, 'uninstall.sh'))
      yield app
    end
  end

  def validate(app)
    Open3.capture3('bash', 'Fork/verify-release.sh', app, TAG, SHA, chdir: ROOT)
  end

  def test_bundle_is_compatible_with_existing_updaters
    with_bundle do |app|
      output, errors, status = validate(app)
      assert status.success?, output + errors
    end
  end

  def test_wrong_identity_repository_version_or_commit_cannot_be_published
    {
      'CFBundleIdentifier' => 'eu.exelban.Stats',
      'CFBundleExecutable' => 'Stats',
      'CompactReleaseRepository' => 'exelban/stats',
      'CompactReleaseTag' => 'v3.0.18-statscompact.1',
      'CompactBuildSHA' => 'b' * 40
    }.each do |key, value|
      with_bundle(key => value) do |app|
        _output, _errors, status = validate(app)
        refute status.success?, "Unexpectedly accepted wrong #{key}"
      end
    end
  end

  def test_packaging_the_wrong_scripts_is_rejected
    %w[updater.sh uninstall.sh].each do |name|
      with_bundle do |app|
        File.write(File.join(app, 'Contents/Resources/Scripts', name), '# wrong script')
        _output, _errors, status = validate(app)
        refute status.success?, "Unexpectedly accepted wrong #{name}"
      end
    end
  end

  def test_uninstaller_dry_run_only_targets_the_fork
    output, errors, status = Open3.capture3('bash', 'Kit/scripts/compact/uninstall.sh',
                                           '--dry-run', '/synthetic home/example', chdir: ROOT)
    assert status.success?, output + errors
    refute_includes output, 'eu.exelban'
    refute_includes output, '/Applications/Stats.app'
    assert_includes output, 'no files or services were changed'
    removals = output.lines.map do |line|
      args = Shellwords.split(line)
      args.last if args[0] == 'rm' || args[0, 2] == ['sudo', 'rm']
    end.compact
    assert_equal 11, removals.length
    removals.each do |path|
      assert path.include?('Stats Compact') || path.include?('com.tovam.StatsCompact'), path
      refute_match(/[?*]/, path)
    end
  end

  def test_uninstaller_rejects_ambiguous_home_paths_without_touching_data
    ['', '/', '/Users', '/Users/../example', '/Users/example/'].each do |path|
      _output, _errors, status = Open3.capture3('bash', 'Kit/scripts/compact/uninstall.sh',
                                              '--dry-run', path, chdir: ROOT)
      refute status.success?, "Accepted ambiguous home path: #{path.inspect}"
    end
  end
end
