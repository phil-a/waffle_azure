import Config

config :waffle,
  storage: Waffle.Storage.Azure,
  bucket: "uploads"

config :waffle_azure,
  account: "testaccount",
  access_key: Base.encode64("test-secret-key"),
  request_options: [plug: {Req.Test, Waffle.Storage.Azure.Client}, retry: false]
