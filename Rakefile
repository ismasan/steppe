# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

desc "Build documentation website from README"
task :docs do
  sh "ruby build_docs.rb"
end
