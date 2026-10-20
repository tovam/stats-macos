#!/usr/bin/env ruby
require 'open3'
require 'yaml'

abort 'Usage: check-build-environment.rb UPSTREAM_REF' unless ARGV.length == 1

def workflow_at(ref, path)
  source, _error, status = Open3.capture3('git', 'show', "#{ref}:#{path}")
  return nil unless status.success?

  YAML.safe_load(source)
end

def environment(workflow)
  job = workflow.fetch('jobs').fetch('build')
  selectors = job.fetch('steps', []).select do |step|
    step['run'].to_s.match?(/\bxcode-select\b|\bDEVELOPER_DIR\b/) ||
      step['uses'].to_s.match?(/setup-xcode|xcode-select/i) ||
      step.fetch('env', {}).key?('DEVELOPER_DIR')
  end.map { |step| step.reject { |key, _| %w[name id].include?(key) } }

  {
    'runs-on' => job.fetch('runs-on'),
    'DEVELOPER_DIR' => job.fetch('env', {}).fetch('DEVELOPER_DIR', workflow.fetch('env', {})['DEVELOPER_DIR']),
    'Xcode selection' => selectors
  }
end

# CI files remain fork-owned. Review upstream toolchain requirements before
# merging source that may require a newer SDK; never activate upstream CI.
upstream = workflow_at(ARGV.first, '.github/workflows/build.yaml')
exit 0 unless upstream # A deleted upstream workflow adds no build requirement.
fork = workflow_at('HEAD', '.github/workflows/fork-build.yaml')
abort 'Missing fork build workflow' unless fork

begin
  expected = environment(upstream)
  actual = environment(fork)
rescue KeyError => error
  abort "::error title=Build environment review required::Cannot compare build workflows: #{error.message}"
end

differences = expected.keys.select { |key| expected[key] != actual[key] }
unless differences.empty?
  puts '::error title=Build environment review required::Upstream runner or Xcode selection differs from the fork. Review and update .github/workflows/fork-build.yaml before syncing source.'
  differences.each do |key|
    puts "#{key}: upstream=#{expected[key].inspect}, fork=#{actual[key].inspect}"
  end
  exit 1
end
