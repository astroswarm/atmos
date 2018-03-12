require 'atmos'
require 'open3'
require 'fileutils'
require 'find'

module Atmos

  class TerraformExecutor
    include GemLogger::LoggerSupport
    include FileUtils

    class ProcessFailed < RuntimeError; end

    def initialize(process_env: ENV)
      @process_env = process_env
    end

    def run(*terraform_args, skip_backend: false, skip_secrets: false)
      setup_working_dir(skip_backend: skip_backend)

      return execute(*terraform_args, skip_secrets: skip_secrets)
    end

    private

    def tf_cmd(*args)
      ['terraform'] + args
    end

    def execute(*terraform_args, skip_secrets: false)
      cmd = tf_cmd(*terraform_args)
      logger.debug("Running terraform: #{cmd.join(' ')}")

      env = Hash[@process_env]
      if ! skip_secrets
        env = env.merge(secrets_env)
      end

      IO.pipe do |stdout, stdout_writer|
        IO.pipe do |stderr, stderr_writer|

          stdout_writer.sync = stderr_writer.sync = true
          # TODO: more filtering on terraform output?
          stdout_thr = pipe_stream(stdout, $stdout)
          stderr_thr = pipe_stream(stderr, $stderr)

          # Was unable to get piping to work with stdin for some reason.  It
          # worked in simple case, but started to fail when terraform config
          # got more extensive.  Thus, using spawn to redirect stdin from the
          # terminal direct to terraform, with IO.pipe to copy the outher
          # streams.  Maybe in the future we can completely disconnect stdin
          # and have atmos do the output parsing and stdin prompting
          pid = spawn(env, *cmd,
                      chdir: Atmos.config.tf_working_dir,
                      :out=>stdout_writer, :err=> stderr_writer, :in => :in)


          logger.debug("Terraform started with pid #{pid}")
          Process.wait(pid)
          stdout_writer.close
          stderr_writer.close
          stdout_thr.join
          stderr_thr.join

          status = $?.exitstatus
          logger.debug("Terraform exited: #{status}")
          if status != 0
            raise ProcessFailed.new "Terraform exited with non-zero exit code: #{status}"
          end

        end
      end

    end

    def setup_working_dir(skip_backend: false)
      logger.debug("Terraform working dir: #{Atmos.config.tf_working_dir}")
      clean_links
      link_support_dirs
      link_recipes
      write_atmos_vars
      setup_backend(skip_backend)
    end

    def setup_backend(skip_backend=false)
      backend_file = File.join(Atmos.config.tf_working_dir, 'atmos-backend.tf.json')
      backend_config = (Atmos.config["backend"] rescue nil).try(:clone)

      if backend_config.present? && ! skip_backend
        logger.debug("Writing out terraform state backend config")
        backend_type = backend_config.delete("type")

        backend = {
            "terraform" => {
                "backend" => {
                    backend_type => backend_config
                }
            }
        }

        File.write(backend_file, JSON.pretty_generate(backend))
      else
        logger.debug("Clearing terraform state backend config")
        File.delete(backend_file) if File.exist?(backend_file)
      end
    end

    # terraform currently (v0.11.3) doesn't handle maps with nested maps or
    # lists well, so flatten them - nested maps get expanded into the top level
    # one, with their keys being appended with underscores, and lists get
    # joined with "," so we end up with a single hash with homogenous types
    def homogenize_for_terraform(h, root={}, prefix="")
      h.each do |k, v|
        if v.is_a? Hash
          homogenize_for_terraform(v, root, "#{k}_")
        else
          v = v.join(",") if v.is_a? Array
          root["#{prefix}#{k}"] = v
        end
      end
      return root
    end

    def write_atmos_vars
      File.open(File.join(Atmos.config.tf_working_dir, 'atmos.auto.tfvars.json'), 'w') do |f|
        var_hash = {
            environment: Atmos.config.atmos_env,
            account_ids: Atmos.config.account_hash,
            atmos_config: homogenize_for_terraform(Atmos.config.to_h)
        }
        f.puts(JSON.pretty_generate(var_hash))
      end
    end

    def secrets_env
      # NOTE use an auto-deleting temp file if passing secrets through env ends
      # up being problematic
      secrets = Atmos.config.provider.secret_manager.to_h
      env_secrets = Hash[secrets.collect { |k, v| ["TF_VAR_#{k}", v] }]
      return env_secrets
    end

    def clean_links
      Find.find(Atmos.config.tf_working_dir) do |f|
        File.delete(f) if File.symlink?(f)
      end
    end

    def link_support_dirs
      ['modules', 'templates'].each do |subdir|
        ln_sf(File.join(Atmos.config.root_dir, subdir), Atmos.config.tf_working_dir)
      end
    end

    def link_recipes
      # recipe_dir = File.join(Atmos.config.tf_working_dir, 'recipes')
      # mkdir_p(recipe_dir)
      recipes = Atmos.config[:recipes]
      recipes.each do |recipe|
        ln_sf(File.join(Atmos.config.root_dir, 'recipes', "#{recipe}.tf"), Atmos.config.tf_working_dir)
      end
    end

    def pipe_stream(src, dest)
       Thread.new do
         block_size = 1024
         begin
           while data = src.readpartial(block_size)
             data = yield data if block_given?
             dest.write(data)
           end
         rescue EOFError
           nil
         rescue Exception => e
           logger.log_exception(e, "Stream failure")
         end
       end
    end

  end

end
