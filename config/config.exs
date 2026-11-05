import Config

# This configuration only applies when working on this project. It is not
# loaded when waffle_azure is used as a dependency.
if config_env() == :test do
  import_config "test.exs"
end
