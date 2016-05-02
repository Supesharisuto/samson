class GitRepository
  include ::NewRelic::Agent::MethodTracer

  attr_reader :repository_url, :repository_directory, :last_pulled
  attr_accessor :executor

  # The directory in which repositories should be cached.
  cattr_accessor(:cached_repos_dir, instance_writer: false) do
    Rails.application.config.samson.cached_repos_dir
  end

  def initialize(repository_url:, repository_dir:, executor: nil)
    @repository_url = repository_url
    @repository_directory = repository_dir
    @executor = executor
  end

  def setup!(temp_dir, git_reference)
    raise ArgumentError.new("git_reference is required") if git_reference.blank?

    executor.output.write("# Beginning git repo setup\n")
    return false unless setup_local_cache!
    return false unless clone!(from: repo_cache_dir, to: temp_dir)
    return false unless checkout!(git_reference, pwd: temp_dir)
    true
  end

  def setup_local_cache!
    if locally_cached?
      update!
    else
      clone!(from: repository_url, to: repo_cache_dir, mirror: true)
    end
  end

  def clone!(from: repository_url, to: repo_cache_dir, mirror: false)
    @last_pulled = Time.now if from == repository_url
    if mirror
      executor.execute!("git -c core.askpass=true clone --mirror #{from} #{to}")
    else
      executor.execute!("git clone #{from} #{to}")
    end
  end
  add_method_tracer :clone!

  def update!
    @last_pulled = Time.now
    executor.execute!("cd #{repo_cache_dir}", 'git fetch -p')
  end
  add_method_tracer :update!

  def commit_from_ref(git_reference, length: 7)
    ensure_local_cache!

    Dir.chdir(repo_cache_dir) do
      # brakeman thinks this is unsafe ... https://github.com/presidentbeef/brakeman/issues/851
      description = IO.popen(['git', 'describe', '--long', '--tags', '--all', "--abbrev=#{length || 40}", git_reference], err: [:child, :out]) do |io|
        io.read.strip
      end

      return nil unless $?.success?

      description.split('-').last.sub(/^g/, '')
    end
  end

  def tag_from_ref(git_reference)
    ensure_local_cache!
    capture_stdout(['git', 'describe', '--tags', git_reference])
  end

  def repo_cache_dir
    File.join(cached_repos_dir, @repository_directory)
  end

  def tags
    cmd = "git for-each-ref refs/tags --sort=-authordate --format='%(refname)' --count=600 | sed 's/refs\\/tags\\///g'"
    success, output = run_single_command(cmd) { |line| line.strip }
    success ? output : []
  end

  def branches
    cmd = 'git branch --list --no-color --no-column'
    success, output = run_single_command(cmd) { |line| line.sub('*', '').strip }
    success ? output : []
  end

  def clean!
    FileUtils.rm_rf(repo_cache_dir)
  end
  add_method_tracer :clean!

  def valid_url?
    return false if repository_url.blank?

    cmd = "git -c core.askpass=true ls-remote -h #{repository_url}"
    valid, output = run_single_command(cmd, pwd: '.')
    Rails.logger.error("Repository Path '#{repository_url}' is invalid: #{output}") unless valid
    valid
  end

  def executor
    @executor ||= TerminalExecutor.new(StringIO.new)
  end

  def file_changed?(sha1, sha2, file)
    executor.execute!("cd #{pwd}", "git diff --quiet --name-only #{sha1}..#{sha2} #{file}")
  end

  def file_content(sha, file)
    raise ArgumentError, "Need a sha, but #{sha} (#{sha.size}) given" unless sha.size == 40
    (locally_cached? && sha_exist?(sha)) || setup_local_cache!
    capture_stdout(["git", "show", "#{sha}:#{file}"])
  end

  private

  def sha_exist?(sha)
    run_single_command("git cat-file -t #{sha}").first
  end

  def ensure_local_cache!
    setup_local_cache! unless locally_cached?
  end

  def checkout!(git_reference, pwd: repo_cache_dir)
    executor.execute!("cd #{pwd}", "git checkout --quiet #{git_reference.shellescape}")
  end

  def locally_cached?
    Dir.exist?(repo_cache_dir)
  end

  def run_single_command(command, pwd: repo_cache_dir)
    tmp_executor = TerminalExecutor.new(StringIO.new)
    success = tmp_executor.execute!("cd #{pwd}", command)
    result = tmp_executor.output.string.lines.map { |line| yield line if block_given? }.uniq.sort
    [success, result]
  end

  # TODO: replace run_single_command with this, because:
  # - correct exit codes
  # - no /r s
  # - no tty colors
  # - array support for input safety
  # - no forced unique + sort
  # - simpler
  def capture_stdout(command)
    Dir.chdir(repo_cache_dir) do
      out = IO.popen(command, err: [:child, :out]) do |io|
        io.read.strip
      end

      out if $?.success?
    end
  end
end
