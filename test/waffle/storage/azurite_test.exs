defmodule Waffle.Storage.AzuriteTest do
  # Runs against a real Blob Storage implementation, which checks the Shared Key
  # and SAS signatures. See the README for how to run these tests.
  use ExUnit.Case, async: false

  alias Waffle.Storage.Azure.Client

  @moduletag :azurite

  # The emulator's well-known development account, which is public and documented:
  # https://learn.microsoft.com/azure/storage/common/storage-use-azurite#well-known-storage-account-and-key
  @account "devstoreaccount1"
  @key "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
  @block_size 4 * 1024 * 1024

  defmodule Upload do
    use Waffle.Definition

    @versions [:original, :thumb]

    def storage_dir(_version, {_file, scope}), do: "uploads/#{scope}"
    def bucket, do: "waffle-azure-test"

    def filename(:thumb, {file, _scope}) do
      "thumb " <> Path.basename(file.file_name, Path.extname(file.file_name))
    end

    def filename(_version, {file, _scope}) do
      Path.basename(file.file_name, Path.extname(file.file_name))
    end

    def s3_object_headers(_version, {_file, _scope}) do
      [content_type: "text/plain", cache_control: "max-age=60"]
    end
  end

  setup_all do
    original = Application.get_all_env(:waffle_azure)
    endpoint = System.get_env("AZURITE_ENDPOINT", "http://127.0.0.1:10000/#{@account}")

    Application.put_env(:waffle_azure, :account, @account)
    Application.put_env(:waffle_azure, :access_key, @key)
    Application.put_env(:waffle_azure, :endpoint, endpoint)
    Application.delete_env(:waffle_azure, :request_options)

    on_exit(fn ->
      Application.delete_env(:waffle_azure, :endpoint)
      Application.put_all_env(waffle_azure: original)
    end)

    {:ok, %{status: status}} =
      Client.request(:put, Upload.bucket(), [restype: "container"], [], "")

    assert status in [201, 409]
    :ok
  end

  setup do
    {:ok, scope: "#{System.unique_integer([:positive])}"}
  end

  defp stored(path) do
    {:ok, response} = Client.request(:get, Upload.bucket() <> "/" <> path)
    response
  end

  @tag :tmp_dir
  test "stores, serves and deletes a small file", %{scope: scope, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "hello world.txt")
    File.write!(path, "hello")

    assert Upload.store({path, scope}) == {:ok, "hello world.txt"}

    response = stored("uploads/#{scope}/hello world.txt")
    assert response.status == 200
    assert response.body == "hello"
    assert Req.Response.get_header(response, "content-type") == ["text/plain"]
    assert Req.Response.get_header(response, "cache-control") == ["max-age=60"]

    assert stored("uploads/#{scope}/thumb hello world.txt").body == "hello"

    assert Upload.delete({"hello world.txt", scope}) == :ok
    assert stored("uploads/#{scope}/hello world.txt").status == 404
    assert stored("uploads/#{scope}/thumb hello world.txt").status == 404
  end

  @tag :tmp_dir
  test "stores a file larger than one block", %{scope: scope, tmp_dir: tmp_dir} do
    contents = :crypto.strong_rand_bytes(@block_size * 2 + 123)
    path = Path.join(tmp_dir, "large.bin")
    File.write!(path, contents)

    assert Upload.store({path, scope}) == {:ok, "large.bin"}

    response = stored("uploads/#{scope}/large.bin")
    assert response.body == contents
    assert Req.Response.get_header(response, "content-type") == ["text/plain"]
  end

  @tag :tmp_dir
  test "stores an empty file", %{scope: scope, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "empty.txt")
    File.write!(path, "")

    assert Upload.store({path, scope}) == {:ok, "empty.txt"}

    response = stored("uploads/#{scope}/empty.txt")
    assert response.status == 200
    assert response.body == ""
  end

  test "stores a binary", %{scope: scope} do
    assert Upload.store({%{filename: "binary.txt", binary: "binary"}, scope}) ==
             {:ok, "binary.txt"}

    assert stored("uploads/#{scope}/binary.txt").body == "binary"
  end

  test "stores a stream", %{scope: scope} do
    stream = Stream.map(["str", "eam"], & &1)

    assert Upload.store({%{filename: "stream.txt", stream: stream}, scope}) ==
             {:ok, "stream.txt"}

    assert stored("uploads/#{scope}/stream.txt").body == "stream"
  end

  test "stores an empty stream", %{scope: scope} do
    stream = Stream.map([], & &1)

    assert Upload.store({%{filename: "empty-stream.txt", stream: stream}, scope}) ==
             {:ok, "empty-stream.txt"}

    response = stored("uploads/#{scope}/empty-stream.txt")
    assert response.status == 200
    assert response.body == ""
  end

  test "handles a non-ASCII file name", %{scope: scope} do
    name = "photo ç+é.txt"

    assert Upload.store({%{filename: name, binary: "unicode"}, scope}) == {:ok, name}
    assert stored("uploads/#{scope}/#{name}").body == "unicode"
    assert Upload.delete({name, scope}) == :ok
    assert stored("uploads/#{scope}/#{name}").status == 404
  end

  test "signed URLs give anonymous access to a private container", %{scope: scope} do
    {:ok, _} = Upload.store({%{filename: "secret file.txt", binary: "secret"}, scope})

    assert Req.get!(Upload.url({"secret file.txt", scope}), retry: false).status in [403, 404]

    signed = Upload.url({"secret file.txt", scope}, :original, signed: true)
    assert %{status: 200, body: "secret"} = Req.get!(signed, retry: false)
  end

  test "deletes by full URL", %{scope: scope} do
    {:ok, _} = Upload.store({%{filename: "by url.txt", binary: "x"}, scope})
    url = Upload.url({"by url.txt", scope})

    assert Waffle.Storage.Azure.delete(Upload, :original, {%{file_name: url}, nil}) == :ok
    assert stored("uploads/#{scope}/by url.txt").status == 404
  end

  test "a wrong key is rejected, showing the emulator does check signatures", %{scope: scope} do
    Application.put_env(:waffle_azure, :access_key, Base.encode64("wrong key"))
    on_exit(fn -> Application.put_env(:waffle_azure, :access_key, @key) end)

    assert {:error, [%Req.Response{status: 403} | _]} =
             Upload.store({%{filename: "x.txt", binary: "x"}, scope})
  end

  test "reports a missing container as an error", %{scope: scope} do
    defmodule NoContainer do
      use Waffle.Definition
      def bucket, do: "waffle-azure-missing"
    end

    assert {:error, [%Req.Response{status: 404}]} =
             NoContainer.store({%{filename: "x.txt", binary: "x"}, scope})
  end
end
