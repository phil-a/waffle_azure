# Waffle Azure Storage Provider

**Provides a [`Waffle`](https://github.com/elixir-waffle/waffle) storage back-end for [`Azure Blob Storage`](https://azure.microsoft.com/en-us/products/storage/blobs).**

Formerly `arc_azure`. If you are upgrading, see [Migrating from arc_azure](#migrating-from-arc_azure).

## Installation

Add `waffle_azure` to your list of dependencies in `mix.exs`. It requires Elixir 1.16 or later.

```elixir
def deps do
  [
    {:waffle_azure, "~> 0.2.0"},
    {:waffle, "~> 2.0"}
  ]
end
```

Run `mix deps.get` in your shell to fetch the dependencies.

## Configuration

Configure Waffle to use the adapter, and give it the name of your container, which must already exist:

```elixir
config :waffle,
  storage: Waffle.Storage.Azure,
  bucket: "uploads"
```

The Azure account and access key are read from these environment variables:

```sh
export AZURE_ACCOUNT=<your-azure-account>
export AZURE_ACCESS_KEY=<your-azure-access-key>
```

Or you can set them in your configuration:

```elixir
config :waffle_azure,
  account: "your-azure-account",
  access_key: "your-azure-access-key"
```

See the `Waffle.Storage.Azure` docs for the other options, including per-uploader containers, CDNs, and blob properties such as the content type.

## Usage

Uploaders work as they do with any other Waffle storage:

```elixir
defmodule MyApp.Avatar do
  use Waffle.Definition

  @versions [:original]

  def storage_dir(_version, {_file, user}), do: "avatars/#{user.id}"

  # Without a content type, browsers download blobs rather than display them.
  def s3_object_headers(_version, {file, _user}) do
    [content_type: MIME.from_path(file.file_name)]
  end
end

{:ok, file_name} = MyApp.Avatar.store({"/path/to/selfie.png", user})

# For a container with anonymous read access
MyApp.Avatar.url({file_name, user})

# For a private container: a read-only URL, valid for an hour
MyApp.Avatar.url({file_name, user}, :original, signed: true, expires_in: 3600)

:ok = MyApp.Avatar.delete({file_name, user})
```

## Migrating from arc_azure

1. Move your uploaders from Arc to Waffle, starting by replacing `use Arc.Definition` with `use Waffle.Definition`.
2. Replace the `arc_azure`, `arc`, and `erlazure` dependencies with the ones under [Installation](#installation).
3. Update your configuration:

| arc_azure | waffle_azure |
| --- | --- |
| `config :arc, storage: Arc.Storage.Azure` | `config :waffle, storage: Waffle.Storage.Azure` |
| `config :arc_azure, container: "uploads"` | `config :waffle, bucket: "uploads"` |
| `config :arc_azure, cdn_url: "https://<account>.blob.core.windows.net"` | Remove it: this is now the default |
| `config :arc_azure, cdn_url: "https://cdn.example.com"` | `config :waffle, asset_host: "https://cdn.example.com/uploads"` (now includes the container) |
| `config :ex_azure, account: ..., access_key: ...` | `config :waffle_azure, account: ..., access_key: ...` |
| `config :arc, default_tempurl_ttl: ...` | Remove it, and pass `expires_in:` with `signed: true` |

Some behaviour has also changed:

* `url` now percent-encodes file names, so a stored `a b.png` gives `a%20b.png` rather than an invalid URL.
* `url` with `signed: true` now returns a working signed URL. It used to be ignored, and the `temp_url_*` options, which had no effect, are gone.
* `delete` now accepts a plain file name when there is no scope, as well as a full URL.
* `delete` logs any failure and still returns `:ok`.
* Blobs keep the same names in the container, so existing files don't need to move.

## Development

```sh
mix deps.get
mix test
```

`mix test` doesn't need network access or an Azure account. To also run the tests against a real Blob Storage implementation, which verifies the request signing, start the [Azurite](https://github.com/Azure/Azurite) emulator and include its tests:

```sh
docker run --rm -p 127.0.0.1:10000:10000 mcr.microsoft.com/azure-storage/azurite azurite-blob --blobHost 0.0.0.0
mix test --include azurite
```

## License

Copyright 2017 Philip Alekseev

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
