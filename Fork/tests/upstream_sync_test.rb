require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'fileutils'

class UpstreamSyncTest < Minitest::Test
  ROOT = File.expand_path('../..', __dir__)
  SCRIPT = File.join(ROOT, 'Fork/sync-upstream.sh')
  GIT_ENV = { 'GIT_CONFIG_NOSYSTEM' => '1', 'GIT_CONFIG_GLOBAL' => '/dev/null' }.freeze

  def git(*args)
    output, error, status = Open3.capture3(GIT_ENV, 'git', *args, chdir: @repo)
    assert status.success?, "git #{args.join(' ')}: #{output}#{error}"
    output.strip
  end

  def write(path, content)
    destination = File.join(@repo, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, content)
  end

  def commit(message)
    git('add', '--all')
    git('commit', '--quiet', '-m', message)
    git('rev-parse', 'HEAD')
  end

  def with_repo
    # Only generated source fixtures in this project; no real repo credentials,
    # user data, installed applications or network operations.
    Dir.mktmpdir('.codex-sync-test-', ROOT) do |directory|
      @repo = directory
      git('init', '--quiet', '--initial-branch=master')
      git('config', 'user.name', 'Synthetic sync test')
      git('config', 'user.email', 'sync@example.invalid')
      git('config', 'commit.gpgsign', 'false')
      git('config', 'core.hooksPath', '.git/no-hooks')
      write('.github/workflows/build.yaml', "name: base\n")
      write('app.swift', "let version = 1\n")
      commit('Base')
      git('branch', 'upstream')
      write('.github/workflows/build.yaml', "name: fork publisher\n")
      write('.github/workflows/fork-build.yaml', "name: fork\n")
      @fork = commit('Fork CI')
      yield
    end
  end

  def upstream_changes
    git('switch', '--quiet', 'upstream')
    yield
    @upstream = commit('Upstream changes')
    git('switch', '--quiet', 'master')
  end

  def sync(ref = 'upstream')
    Open3.capture3(GIT_ENV, 'bash', SCRIPT, ref, chdir: @repo)
  end

  def assert_workflows_preserved
    assert_empty git('diff', @fork, '--', '.github/workflows')
  end

  def test_code_merges_and_conflicting_or_new_workflows_are_kept_for_review
    with_repo do
      upstream_changes do
        write('app.swift', "let version = 2\n")
        write('.github/workflows/build.yaml', "name: changed upstream CI\n")
        write('.github/workflows/release.yaml', "name: upstream release\n")
      end
      output, error, status = sync
      assert status.success?, output + error
      assert_includes output, 'Upstream CI changes need review'
      assert_workflows_preserved
      assert_equal "let version = 2\n", File.read(File.join(@repo, 'app.swift'))
      assert_equal [@fork, @upstream], git('show', '-s', '--format=%P', 'HEAD').split
      assert_empty git('status', '--porcelain')
    end
  end

  def test_upstream_workflow_deletion_does_not_delete_fork_ci
    with_repo do
      upstream_changes { git('rm', '.github/workflows/build.yaml') }
      output, error, status = sync
      assert status.success?, output + error
      assert_workflows_preserved
    end
  end

  def test_source_conflicts_still_fail_and_are_not_silently_resolved
    with_repo do
      write('app.swift', "let version = 10\n")
      @fork = commit('Fork source change')
      upstream_changes { write('app.swift', "let version = 20\n") }
      output, error, status = sync
      refute status.success?, output + error
      assert_includes output, 'Upstream source conflict'
      assert_equal @fork, git('rev-parse', 'HEAD')
      assert_equal 'app.swift', git('diff', '--name-only', '--diff-filter=U')
      assert_workflows_preserved
    end
  end

  def test_non_conflicting_source_changes_on_both_sides_are_preserved
    with_repo do
      write('fork.swift', "let compact = true\n")
      @fork = commit('Fork feature')
      upstream_changes { write('app.swift', "let version = 2\n") }
      output, error, status = sync
      assert status.success?, output + error
      refute_includes output, 'Upstream CI changes need review'
      assert_equal "let compact = true\n", File.read(File.join(@repo, 'fork.swift'))
      assert_workflows_preserved
    end
  end

  def test_repeat_sync_does_not_create_empty_commits
    with_repo do
      upstream_changes { write('app.swift', "let version = 2\n") }
      _output, _error, status = sync
      assert status.success?
      merged = git('rev-parse', 'HEAD')
      output, error, status = sync
      assert status.success?, output + error
      assert_includes output, 'already integrated'
      assert_equal merged, git('rev-parse', 'HEAD')
    end
  end

  def test_modified_and_untracked_files_are_not_overwritten
    %w[app.swift untracked.swift].each do |path|
      with_repo do
        upstream_changes { write('app.swift', "let version = 2\n") }
        write(path, "local work\n")
        output, _error, status = sync
        refute status.success?
        assert_includes output, 'Dirty checkout'
        assert_equal "local work\n", File.read(File.join(@repo, path))
        assert_equal @fork, git('rev-parse', 'HEAD')
      end
    end
  end

  def test_invalid_upstream_ref_is_rejected_without_changes
    with_repo do
      _output, _error, status = sync('missing-ref')
      refute status.success?
      assert_equal @fork, git('rev-parse', 'HEAD')
      assert_empty git('status', '--porcelain')
    end
  end
end
