# frozen_string_literal: true

require "rake/testtask"
require "rubocop/rake_task"

# rake test (or just rake): runs every test/*_test.rb
Rake::TestTask.new do |task|
  task.pattern = "test/*_test.rb"
end

RuboCop::RakeTask.new(:lint)

task default: :test
