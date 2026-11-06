defmodule Waffle.Storage.Azure do
  @moduledoc """
  A [Waffle](https://hexdocs.pm/waffle) storage adapter for Azure Blob Storage.

      config :waffle,
        storage: Waffle.Storage.Azure,
        bucket: "uploads"

      config :waffle_azure,
        account: System.get_env("AZURE_ACCOUNT"),
        access_key: System.get_env("AZURE_ACCESS_KEY")

  `:account` and `:access_key` fall back to the `AZURE_ACCOUNT` and
  `AZURE_ACCESS_KEY` environment variables when they are not configured.

  ## Managed identity

  On Azure, the adapter can authenticate with the app's managed identity through
  Microsoft Entra ID, instead of an access key:

      config :waffle_azure,
        account: "myaccount",
        credential: :managed_identity

  That uses the system-assigned identity. For a user-assigned identity, pass its
  client ID:

      config :waffle_azure,
        account: "myaccount",
        credential: {:managed_identity, client_id: "00000000-0000-0000-0000-000000000000"}

  It works on App Service, Azure Functions and Container Apps, and on hosts with
  the Instance Metadata Service, such as VMs and AKS nodes. The identity needs
  the Storage Blob Data Contributor role on the storage account or container.

  Tokens are cached until shortly before they expire. If one can't be fetched,
  `put/3` returns `{:error, %Waffle.Storage.Azure.AuthError{}}`.

  Signed URLs become user delegation SAS URLs, which are signed with a key the
  identity requests from Azure. They can be valid for up to 7 days, less an hour.
  If the key can't be fetched, `url/4` raises `Waffle.Storage.Azure.AuthError`.

  `:credential` defaults to `:shared_key`, which uses `:access_key`.

  ## Containers

  Waffle's `:bucket` is the name of the Azure container, which must already
  exist. As with other Waffle storage adapters, it can be read from the
  environment with `{:system, "VAR"}`, or set per uploader by overriding
  `bucket/0` or `bucket/1` in the definition module.

  ## URLs

  By default, URLs have the form
  `https://<account>.blob.core.windows.net/<container>/<path>`. Reading from
  such a URL needs a container with anonymous read access enabled.

  For a private container, generate a read-only shared access signature with
  `signed: true`. It expires after 5 minutes unless `:expires_in` (in seconds)
  says otherwise:

      Avatar.url({"selfie.png", user}, :thumb, signed: true, expires_in: 3600)

  To serve files from a CDN, set Waffle's `:asset_host`. It replaces both the
  account endpoint and the container, so it should map to the container's root.
  Signed URLs ignore it, because they are always served by the storage account.

      config :waffle,
        asset_host: "https://cdn.example.com"

  ## Blob properties

  Blob properties are set through `s3_object_headers/2`, the hook Waffle provides
  for object headers. It returns a keyword list or map, and supports these keys:

    * `:cache_control`
    * `:content_disposition`
    * `:content_encoding`
    * `:content_language`
    * `:content_md5`
    * `:content_type`

  Lowercase string keys starting with `x-ms-`, such as `"x-ms-access-tier"` or
  `"x-ms-meta-owner"`, are sent as they are. Any other key is ignored, so that a
  definition can be shared with other storage adapters.

  Azure stores blobs as `application/octet-stream` unless told otherwise, so
  browsers will download rather than display them without a content type:

      def s3_object_headers(_version, {file, _scope}) do
        [content_type: MIME.from_path(file.file_name)]
      end

  ## Other options

    * `:endpoint` - the Blob service URL, for sovereign clouds or the
      [Azurite](https://github.com/Azure/Azurite) emulator
    * `:request_options` - options merged into `Req.new/1`, such as
      `:receive_timeout`

  Files larger than 4 MiB and streams are uploaded in blocks of at least 4 MiB.
  Waffle gives each version 15 seconds to upload by default, so raise its
  `:version_timeout` if you expect to store large files.
  """

  @behaviour Waffle.Storage

  require Logger

  alias Waffle.Definition.Versioning
  alias Waffle.Storage.Azure.Client

  @block_size 4 * 1024 * 1024
  @default_expires_in 5 * 60

  @blob_headers %{
    cache_control: "x-ms-blob-cache-control",
    content_disposition: "x-ms-blob-content-disposition",
    content_encoding: "x-ms-blob-content-encoding",
    content_language: "x-ms-blob-content-language",
    content_md5: "x-ms-blob-content-md5",
    content_type: "x-ms-blob-content-type"
  }

  @doc """
  Uploads a file to the container.

  Returns `{:ok, file_name}`, or `{:error, reason}` where `reason` is the
  `Req.Response` or exception that made the upload fail.
  """
  @impl true
  def put(definition, version, {file, scope}) do
    container = container(definition, {file, scope})
    blob = blob_name(definition.storage_dir(version, {file, scope}), file.file_name)

    headers =
      version
      |> definition.s3_object_headers({file, scope})
      |> blob_headers()

    with :ok <- upload(file, container, blob, headers) do
      {:ok, file.file_name}
    end
  end

  @doc """
  Builds the URL of an uploaded file.

  Pass `signed: true` for a read-only URL that also works on a private container,
  and `:expires_in` to set how many seconds it stays valid.

  With a managed identity, signing needs a user delegation key from Azure, so it
  raises `Waffle.Storage.Azure.AuthError` if the key can't be fetched.
  """
  @impl true
  def url(definition, version, file_and_scope, options \\ []) do
    blob = stored_blob_name(definition, version, file_and_scope)

    if Keyword.get(options, :signed, false) do
      expires_in = options[:expires_in] || options[:expire_in] || @default_expires_in
      Client.signed_blob_url(container(definition, file_and_scope), blob, expires_in)
    else
      public_url(definition, file_and_scope, blob)
    end
  end

  @doc """
  Deletes a file from the container.

  The file may be given by name, or by the full URL returned by `url/4`. Always
  returns `:ok`, as Waffle ignores the result. Failures are logged instead.
  """
  @impl true
  def delete(definition, version, file_and_scope) do
    container = container(definition, file_and_scope)
    blob = blob_to_delete(definition, version, file_and_scope)

    case Client.delete_blob(container, blob) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete Azure blob #{container}/#{blob}: #{inspect(reason)}")
        :ok
    end
  end

  #
  # Private
  #

  defp upload(%{binary: binary}, container, blob, headers) when is_binary(binary) do
    Client.put_blob(container, blob, binary, headers)
  end

  defp upload(%{stream: stream}, container, blob, headers) when not is_nil(stream) do
    stream
    |> chunk_into_blocks()
    |> upload_blocks(container, blob, headers)
  end

  defp upload(%{path: path}, container, blob, headers) do
    if File.stat!(path).size <= @block_size do
      Client.put_blob(container, blob, File.read!(path), headers)
    else
      path
      |> File.stream!(@block_size)
      |> upload_blocks(container, blob, headers)
    end
  end

  # A stream's elements can be any size. Azure allows 50,000 blocks per blob, so
  # small elements have to be combined for large uploads to fit within that.
  defp chunk_into_blocks(stream) do
    Stream.chunk_while(
      stream,
      "",
      fn chunk, buffer ->
        buffer = buffer <> IO.iodata_to_binary(chunk)

        if byte_size(buffer) >= @block_size do
          {:cont, buffer, ""}
        else
          {:cont, buffer}
        end
      end,
      fn
        "" -> {:cont, ""}
        buffer -> {:cont, buffer, ""}
      end
    )
  end

  defp upload_blocks(blocks, container, blob, headers) do
    # Unique per upload, so that concurrent uploads to the same blob can't
    # commit each other's blocks.
    upload_id = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64()

    blocks
    |> Stream.with_index()
    |> Enum.reduce_while({:ok, []}, fn {block, index}, {:ok, block_ids} ->
      block_id = block_id(upload_id, index)

      case Client.put_block(container, blob, block_id, block) do
        :ok -> {:cont, {:ok, [block_id | block_ids]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, block_ids} ->
        Client.put_block_list(container, blob, Enum.reverse(block_ids), headers)

      {:error, _reason} = error ->
        error
    end
  end

  # All the block IDs of a blob must be the same length.
  defp block_id(upload_id, index) do
    index = index |> Integer.to_string() |> String.pad_leading(5, "0")
    Base.encode64("#{upload_id}-#{index}")
  end

  defp blob_headers(headers) do
    Enum.flat_map(headers, fn
      {key, value} when is_map_key(@blob_headers, key) ->
        [{Map.fetch!(@blob_headers, key), to_string(value)}]

      {"x-ms-" <> _ = name, value} ->
        [{name, to_string(value)}]

      _other ->
        []
    end)
  end

  defp blob_to_delete(definition, version, {file, _scope} = file_and_scope) do
    prefix = public_url(definition, file_and_scope, "")

    if String.starts_with?(file.file_name, prefix) do
      file.file_name
      |> String.replace_prefix(prefix, "")
      |> URI.decode()
    else
      stored_blob_name(definition, version, file_and_scope)
    end
  end

  defp stored_blob_name(definition, version, file_and_scope) do
    blob_name(
      definition.storage_dir(version, file_and_scope),
      Versioning.resolve_file_name(definition, version, file_and_scope)
    )
  end

  defp blob_name(storage_dir, file_name) do
    storage_dir
    |> Path.join(file_name)
    |> String.trim_leading("/")
  end

  defp public_url(definition, file_and_scope, blob) do
    case asset_host(definition) do
      host when host in [nil, false] ->
        Client.blob_url(container(definition, file_and_scope), blob)

      host ->
        String.trim_trailing(host, "/") <> "/" <> Client.encode_path(blob)
    end
  end

  defp container(definition, file_and_scope) do
    file_and_scope
    |> definition.bucket()
    |> resolve_system()
  end

  defp asset_host(definition), do: resolve_system(definition.asset_host())

  defp resolve_system({:system, env_var}) when is_binary(env_var), do: System.get_env(env_var)
  defp resolve_system(value), do: value
end
