defmodule Waffle.Storage.AzureTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Waffle.Storage.Azure

  @account "testaccount"
  @key "test-secret-key"
  @block_size 4 * 1024 * 1024
  @host "https://testaccount.blob.core.windows.net"

  defmodule Avatar do
    use Waffle.Definition

    @versions [:original, :thumb]

    def storage_dir(_version, {_file, scope}), do: "avatars/#{scope}"
    def filename(version, _file_and_scope), do: version

    def s3_object_headers(:thumb, _file_and_scope) do
      %{
        :content_type => "image/png",
        :cache_control => "max-age=60",
        :acl => :public_read,
        "x-ms-meta-owner" => "phil"
      }
    end
  end

  defmodule Document do
    use Waffle.Definition

    def storage_dir(_version, _file_and_scope), do: "/docs"
    def bucket({_file, scope}), do: scope
    def asset_host, do: {:system, "WAFFLE_AZURE_TEST_ASSET_HOST"}
  end

  # Records every request for the test to inspect, and answers with `status`.
  defp stub_azure(status \\ 201) do
    test = self()

    Req.Test.stub(Azure.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 64 * 1024 * 1024)
      send(test, {:request, %{conn | query_params: URI.decode_query(conn.query_string)}, body})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value] -> value
      [] -> nil
    end
  end

  defp waffle_file(attrs), do: struct!(%Waffle.File{file_name: "a.png"}, attrs)

  defp temp_file(context, contents) do
    path = Path.join(context.tmp_dir, "upload")
    File.write!(path, contents)
    path
  end

  describe "put/3" do
    @describetag :tmp_dir

    test "uploads a small file as a single blob", context do
      stub_azure()
      file = waffle_file(path: temp_file(context, "contents"))

      assert Azure.put(Avatar, :original, {file, "1"}) == {:ok, "a.png"}

      assert_received {:request, conn, "contents"}
      assert conn.method == "PUT"
      assert conn.host == "testaccount.blob.core.windows.net"
      assert conn.request_path == "/uploads/avatars/1/a.png"
      assert header(conn, "x-ms-blob-type") == "BlockBlob"
      refute_received {:request, _conn, _body}
    end

    test "uploads a binary as a single blob" do
      stub_azure()

      assert Azure.put(Avatar, :original, {waffle_file(binary: "binary"), "1"}) == {:ok, "a.png"}
      assert_received {:request, _conn, "binary"}
    end

    test "signs the request with the documented Shared Key format", context do
      stub_azure()
      file = waffle_file(path: temp_file(context, "contents"), file_name: "a b.png")

      assert {:ok, _} = Azure.put(Avatar, :thumb, {file, "1"})
      assert_received {:request, conn, _body}
      assert conn.request_path == "/uploads/avatars/1/a%20b.png"

      string_to_sign =
        "PUT\n\n\n8\n\n\n\n\n\n\n\n\n" <>
          "x-ms-blob-cache-control:max-age=60\n" <>
          "x-ms-blob-content-type:image/png\n" <>
          "x-ms-blob-type:BlockBlob\n" <>
          "x-ms-date:#{header(conn, "x-ms-date")}\n" <>
          "x-ms-meta-owner:phil\n" <>
          "x-ms-version:2021-12-02\n" <>
          "/testaccount/uploads/avatars/1/a%20b.png"

      assert header(conn, "authorization") == "SharedKey #{@account}:#{sign(string_to_sign)}"
    end

    test "uses an RFC 1123 date", context do
      stub_azure()

      assert {:ok, _} =
               Azure.put(Avatar, :original, {waffle_file(path: temp_file(context, "x")), "1"})

      assert_received {:request, conn, _body}

      assert header(conn, "x-ms-date") =~
               ~r/^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$/
    end

    test "maps object headers to blob properties and ignores unknown ones", context do
      stub_azure()

      assert {:ok, _} =
               Azure.put(Avatar, :thumb, {waffle_file(path: temp_file(context, "x")), "1"})

      assert_received {:request, conn, _body}
      assert header(conn, "x-ms-blob-content-type") == "image/png"
      assert header(conn, "x-ms-blob-cache-control") == "max-age=60"
      assert header(conn, "x-ms-meta-owner") == "phil"
      refute List.keymember?(conn.req_headers, "acl", 0)
      refute List.keymember?(conn.req_headers, "x-ms-acl", 0)
    end

    test "uploads a large file in ordered blocks and commits them", context do
      stub_azure()
      first = :binary.copy("a", @block_size)
      file = waffle_file(path: temp_file(context, first <> "tail"))

      assert Azure.put(Avatar, :thumb, {file, "1"}) == {:ok, "a.png"}

      assert_received {:request, block1, ^first}
      assert_received {:request, block2, "tail"}
      assert_received {:request, commit, commit_body}

      assert block1.query_params["comp"] == "block"
      assert block2.query_params["comp"] == "block"
      assert commit.query_params["comp"] == "blocklist"

      ids = [block1.query_params["blockid"], block2.query_params["blockid"]]
      assert byte_size(hd(ids)) == byte_size(List.last(ids))
      assert commit_body =~ "<Latest>#{hd(ids)}</Latest><Latest>#{List.last(ids)}</Latest>"

      # Properties belong to the blob, so they are set on commit rather than per block.
      assert header(block1, "x-ms-blob-content-type") == nil
      assert header(commit, "x-ms-blob-content-type") == "image/png"
    end

    test "signs the decoded block ID in the canonicalized resource", context do
      stub_azure()
      contents = :binary.copy("a", @block_size + 1)

      assert {:ok, _} =
               Azure.put(
                 Avatar,
                 :original,
                 {waffle_file(path: temp_file(context, contents)), "1"}
               )

      assert_received {:request, conn, _body}
      block_id = conn.query_params["blockid"]

      string_to_sign =
        "PUT\n\n\n#{@block_size}\n\n\n\n\n\n\n\n\n" <>
          "x-ms-date:#{header(conn, "x-ms-date")}\n" <>
          "x-ms-version:2021-12-02\n" <>
          "/testaccount/uploads/avatars/1/a.png\nblockid:#{block_id}\ncomp:block"

      assert header(conn, "authorization") == "SharedKey #{@account}:#{sign(string_to_sign)}"
    end

    test "combines a stream's small elements into blocks" do
      stub_azure()
      element = :binary.copy("a", 1024 * 1024)
      stream = Stream.map(1..5, fn _ -> element end)

      assert Azure.put(Avatar, :original, {waffle_file(stream: stream), "1"}) == {:ok, "a.png"}

      expected_block = :binary.copy(element, 4)
      assert_received {:request, _conn, ^expected_block}
      assert_received {:request, _conn, ^element}
      assert_received {:request, commit, _body}
      assert commit.query_params["comp"] == "blocklist"
    end

    test "commits an empty block list for an empty stream" do
      stub_azure()
      stream = Stream.map([], & &1)

      assert Azure.put(Avatar, :original, {waffle_file(stream: stream), "1"}) == {:ok, "a.png"}

      assert_received {:request, commit, body}
      assert commit.query_params["comp"] == "blocklist"
      assert body =~ "<BlockList></BlockList>"
      refute_received {:request, _conn, _body}
    end

    test "returns the response when Azure rejects the upload", context do
      stub_azure(403)
      file = waffle_file(path: temp_file(context, "x"))

      assert {:error, %Req.Response{status: 403}} = Azure.put(Avatar, :original, {file, "1"})
    end

    test "returns the exception when the connection fails", context do
      Req.Test.stub(Azure.Client, &Req.Test.transport_error(&1, :econnrefused))
      file = waffle_file(path: temp_file(context, "x"))

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Azure.put(Avatar, :original, {file, "1"})
    end

    test "stops without committing when a block fails" do
      test = self()

      Req.Test.stub(Azure.Client, fn conn ->
        send(test, {:query, URI.decode_query(conn.query_string)["comp"]})
        Plug.Conn.send_resp(conn, 500, "")
      end)

      stream = Stream.map(1..2, fn _ -> :binary.copy("a", @block_size) end)

      assert {:error, %Req.Response{status: 500}} =
               Azure.put(Avatar, :original, {waffle_file(stream: stream), "1"})

      assert_received {:query, "block"}
      refute_received {:query, _comp}
    end

    test "does not put a leading slash from storage_dir in the blob name", context do
      stub_azure()
      file = waffle_file(path: temp_file(context, "x"))

      assert {:ok, _} = Azure.put(Document, :original, {file, "reports"})

      assert_received {:request, conn, _body}
      assert conn.request_path == "/reports/docs/a.png"
    end
  end

  describe "url/4" do
    test "builds a URL from the account and container" do
      assert Azure.url(Avatar, :thumb, {%{file_name: "a.png"}, "1"}) ==
               "#{@host}/uploads/avatars/1/thumb.png"
    end

    test "encodes path segments but not their separators" do
      assert Azure.url(Document, :original, {%{file_name: "a b#ç.png"}, "reports"}) ==
               "#{@host}/reports/docs/a%20b%23%C3%A7.png"
    end

    test "uses asset_host in place of the account and container" do
      System.put_env("WAFFLE_AZURE_TEST_ASSET_HOST", "https://cdn.example.com/")
      on_exit(fn -> System.delete_env("WAFFLE_AZURE_TEST_ASSET_HOST") end)

      assert Azure.url(Document, :original, {%{file_name: "a.png"}, "reports"}) ==
               "https://cdn.example.com/docs/a.png"
    end

    test "uses the configured endpoint" do
      Application.put_env(:waffle_azure, :endpoint, "http://127.0.0.1:10000/account/")
      on_exit(fn -> Application.delete_env(:waffle_azure, :endpoint) end)

      assert Azure.url(Avatar, :thumb, {%{file_name: "a.png"}, "1"}) ==
               "http://127.0.0.1:10000/account/uploads/avatars/1/thumb.png"
    end

    test "reads the container from the environment" do
      System.put_env("WAFFLE_AZURE_TEST_BUCKET", "from-env")
      original = Application.get_env(:waffle, :bucket)
      Application.put_env(:waffle, :bucket, {:system, "WAFFLE_AZURE_TEST_BUCKET"})

      on_exit(fn ->
        Application.put_env(:waffle, :bucket, original)
        System.delete_env("WAFFLE_AZURE_TEST_BUCKET")
      end)

      assert Azure.url(Avatar, :thumb, {%{file_name: "a.png"}, "1"}) ==
               "#{@host}/from-env/avatars/1/thumb.png"
    end

    test "signs a read-only URL with the documented service SAS format" do
      url = Azure.url(Avatar, :thumb, {%{file_name: "a b.png"}, "1"}, signed: true)
      uri = URI.parse(url)
      query = URI.decode_query(uri.query)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "#{@host}/uploads/avatars/1/thumb.png"
      assert %{"sp" => "r", "sr" => "b", "sv" => "2021-12-02"} = query

      string_to_sign =
        "r\n\n#{query["se"]}\n/blob/testaccount/uploads/avatars/1/thumb.png" <>
          "\n\n\n\n2021-12-02\nb\n\n\n\n\n\n\n"

      assert query["sig"] == sign(string_to_sign)
    end

    test "canonicalizes a signed URL's blob name unencoded" do
      url = Azure.url(Document, :original, {%{file_name: "a b.png"}, "reports"}, signed: true)
      query = URI.decode_query(URI.parse(url).query)

      assert url =~ "/reports/docs/a%20b.png?"

      string_to_sign =
        "r\n\n#{query["se"]}\n/blob/testaccount/reports/docs/a b.png" <>
          "\n\n\n\n2021-12-02\nb\n\n\n\n\n\n\n"

      assert query["sig"] == sign(string_to_sign)
    end

    test "expires a signed URL after 5 minutes by default" do
      assert_in_delta seconds_until_expiry(signed: true), 300, 5
    end

    test "honours expires_in and Waffle's older expire_in on signed URLs" do
      assert_in_delta seconds_until_expiry(signed: true, expires_in: 3600), 3600, 5
      assert_in_delta seconds_until_expiry(signed: true, expire_in: 60), 60, 5
    end

    test "ignores asset_host on signed URLs" do
      System.put_env("WAFFLE_AZURE_TEST_ASSET_HOST", "https://cdn.example.com")
      on_exit(fn -> System.delete_env("WAFFLE_AZURE_TEST_ASSET_HOST") end)

      url = Azure.url(Document, :original, {%{file_name: "a.png"}, "reports"}, signed: true)
      assert String.starts_with?(url, "#{@host}/reports/docs/a.png?")
    end

    defp seconds_until_expiry(options) do
      url = Azure.url(Avatar, :thumb, {%{file_name: "a.png"}, "1"}, options)
      expiry = URI.decode_query(URI.parse(url).query)["se"]
      {:ok, expiry, 0} = DateTime.from_iso8601(expiry)
      DateTime.diff(expiry, DateTime.utc_now())
    end
  end

  describe "delete/3" do
    test "deletes the resolved blob" do
      stub_azure(202)

      assert Azure.delete(Avatar, :thumb, {%{file_name: "a.png"}, "1"}) == :ok

      assert_received {:request, conn, ""}
      assert conn.method == "DELETE"
      assert conn.request_path == "/uploads/avatars/1/thumb.png"
    end

    test "works with a plain file name and no scope" do
      stub_azure(202)

      assert Azure.delete(Avatar, :thumb, {%{file_name: "a.png"}, nil}) == :ok

      assert_received {:request, conn, ""}
      assert conn.request_path == "/uploads/avatars/thumb.png"
    end

    test "deletes by full URL, without needing the scope" do
      stub_azure(202)
      url = "#{@host}/uploads/some%20dir/a%20b.png"

      assert Azure.delete(Avatar, :original, {%{file_name: url}, nil}) == :ok

      assert_received {:request, conn, ""}
      assert conn.request_path == "/uploads/some%20dir/a%20b.png"
    end

    test "treats a missing blob as deleted" do
      stub_azure(404)

      log =
        capture_log(fn ->
          assert Azure.delete(Avatar, :thumb, {%{file_name: "a.png"}, "1"}) == :ok
        end)

      assert log == ""
    end

    test "logs other failures" do
      stub_azure(403)

      log =
        capture_log(fn ->
          assert Azure.delete(Avatar, :thumb, {%{file_name: "a.png"}, "1"}) == :ok
        end)

      assert log =~ "Failed to delete Azure blob uploads/avatars/1/thumb.png"
    end
  end

  describe "through a Waffle definition" do
    @describetag :tmp_dir

    test "stores every version under its resolved name", context do
      stub_azure()
      path = temp_file(context, "x")

      assert Avatar.store({%{filename: "a.png", path: path}, "1"}) == {:ok, "a.png"}

      assert_received {:request, first, "x"}
      assert_received {:request, second, "x"}

      assert Enum.sort([first.request_path, second.request_path]) == [
               "/uploads/avatars/1/original.png",
               "/uploads/avatars/1/thumb.png"
             ]
    end

    test "stores an uploaded binary and a stream" do
      stub_azure()

      assert {:ok, "a.png"} = Avatar.store({%{filename: "a.png", binary: "binary"}, "1"})
      assert_received {:request, _conn, "binary"}

      stream = Stream.map(["str", "eam"], & &1)
      assert {:ok, "a.png"} = Avatar.store({%{filename: "a.png", stream: stream}, "1"})
      assert_received {:request, _conn, "stream"}
    end

    test "reports a failed upload", context do
      stub_azure(403)
      path = temp_file(context, "x")

      assert {:error, [%Req.Response{status: 403}, %Req.Response{status: 403}]} =
               Avatar.store({%{filename: "a.png", path: path}, "1"})
    end

    test "builds URLs for every version" do
      assert Avatar.urls({"a.png", "1"}) == %{
               original: "#{@host}/uploads/avatars/1/original.png",
               thumb: "#{@host}/uploads/avatars/1/thumb.png"
             }
    end

    test "passes signing options through" do
      assert Avatar.url({"a.png", "1"}, :thumb, signed: true) =~ "&sig="
    end

    test "deletes every version" do
      stub_azure(202)

      assert Avatar.delete({"a.png", "1"}) == :ok

      assert_received {:request, first, ""}
      assert_received {:request, second, ""}
      assert first.method == "DELETE"
      assert second.method == "DELETE"
    end
  end

  describe "configuration" do
    test "falls back to the documented environment variables" do
      original = Application.get_env(:waffle_azure, :account)
      Application.delete_env(:waffle_azure, :account)
      System.put_env("AZURE_ACCOUNT", "fromenv")

      on_exit(fn ->
        Application.put_env(:waffle_azure, :account, original)
        System.delete_env("AZURE_ACCOUNT")
      end)

      assert Azure.url(Avatar, :thumb, {%{file_name: "a.png"}, "1"}) ==
               "https://fromenv.blob.core.windows.net/uploads/avatars/1/thumb.png"
    end

    test "raises a helpful error when credentials are missing" do
      original = Application.get_env(:waffle_azure, :account)
      Application.delete_env(:waffle_azure, :account)
      on_exit(fn -> Application.put_env(:waffle_azure, :account, original) end)

      assert_raise ArgumentError, ~r/AZURE_ACCOUNT/, fn ->
        Azure.url(Avatar, :thumb, {%{file_name: "a.png"}, "1"})
      end
    end
  end

  defp sign(string_to_sign) do
    :hmac |> :crypto.mac(:sha256, @key, string_to_sign) |> Base.encode64()
  end
end
