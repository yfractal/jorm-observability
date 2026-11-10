namespace :greptime do
  desc "Apply GreptimeDB primary schema (traces, trace_to_metrics)"
  task prepare: :environment do
    Greptime::Schema.load!
    puts "GreptimeDB primary schema ready"
  end
end

# Hook into db:prepare so Docker/local bootstraps Greptime + queue together.
Rake::Task["db:prepare"].enhance([ "greptime:prepare" ]) if Rake::Task.task_defined?("db:prepare")
