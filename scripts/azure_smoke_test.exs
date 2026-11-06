# End-to-end check of the published waffle_azure package against a real storage
# account. It installs the package from Hex, so it tests what users actually get.
#
#     export AZURE_ACCOUNT=<your-azure-account>
#     export AZURE_ACCESS_KEY=<your-azure-access-key>
#     export AZURE_TEST_CONTAINER=<an-existing-container>
#     elixir scripts/azure_smoke_test.exs
#
# Set AZURE_ENDPOINT as well to use a sovereign cloud or the Azurite emulator.
#
# To test with the managed identity of the Azure host the script runs on, set
# AZURE_CREDENTIAL=managed_identity instead of AZURE_ACCESS_KEY. For a
# user-assigned identity, also set AZURE_CLIENT_ID.
#
# To test unreleased code, set WAFFLE_AZURE_PATH to a checkout of this
# repository. Otherwise the version below is installed from Hex.
#
# Everything happens under a new, uniquely named folder in the container, and is
# deleted at the end. Containers aren't created or changed. The script exits with
# status 0 if every check passes, 1 if any fail, and 2 if it's missing settings.
#
# The key, tokens and URL signatures are left out of the output, so it's safe to
# share, though error details from Azure can include your account name.

Mix.install([
  case System.get_env("WAFFLE_AZURE_PATH") do
    path when path in [nil, ""] -> {:waffle_azure, "0.2.0"}
    path -> {:waffle_azure, path: Path.expand(path)}
  end
])

managed_identity? =
  case System.get_env("AZURE_CREDENTIAL") do
    value when value in [nil, "", "shared_key"] ->
      false

    "managed_identity" ->
      true

    other ->
      IO.puts(:stderr, "AZURE_CREDENTIAL must be shared_key or managed_identity, not #{other}")
      System.halt(2)
  end

required =
  if managed_identity?,
    do: ~w(AZURE_ACCOUNT AZURE_TEST_CONTAINER),
    else: ~w(AZURE_ACCOUNT AZURE_ACCESS_KEY AZURE_TEST_CONTAINER)

missing = Enum.filter(required, &(System.get_env(&1) in [nil, ""]))

if missing != [] do
  IO.puts(:stderr, "Missing environment variables: #{Enum.join(missing, ", ")}")
  System.halt(2)
end

Application.put_env(:waffle_azure, :account, System.fetch_env!("AZURE_ACCOUNT"))

if managed_identity? do
  credential =
    case System.get_env("AZURE_CLIENT_ID") do
      client_id when client_id in [nil, ""] -> :managed_identity
      client_id -> {:managed_identity, client_id: client_id}
    end

  Application.put_env(:waffle_azure, :credential, credential)
else
  if Base.decode64(System.fetch_env!("AZURE_ACCESS_KEY")) == :error do
    IO.puts(:stderr, "AZURE_ACCESS_KEY isn't valid base64. Check it was copied in full.")
    System.halt(2)
  end

  Application.put_env(:waffle_azure, :access_key, System.fetch_env!("AZURE_ACCESS_KEY"))
end

if endpoint = System.get_env("AZURE_ENDPOINT") do
  Application.put_env(:waffle_azure, :endpoint, endpoint)
end

Application.put_env(:waffle, :storage, Waffle.Storage.Azure)
Application.put_env(:waffle, :bucket, System.fetch_env!("AZURE_TEST_CONTAINER"))
Application.put_env(:waffle, :version_timeout, 120_000)

# A failed delete logs Azure's whole response, which can include a signature.
# The cleanup step below reports anything it couldn't remove instead.
Logger.configure(level: :error)

defmodule Smoke.Upload do
  use Waffle.Definition

  @versions [:original]

  def storage_dir(_version, {_file, folder}), do: folder

  def s3_object_headers(_version, {_file, _folder}) do
    [content_type: "text/plain", cache_control: "max-age=60"]
  end
end

defmodule Smoke do
  alias Smoke.Upload

  def check(label, fun) do
    fun.()
    IO.puts("PASS  #{label}")
    true
  rescue
    error ->
      Process.put(:failures, Process.get(:failures, 0) + 1)
      IO.puts("FAIL  #{label}\n      #{scrub(Exception.message(error))}")
      false
  end

  def ensure!(true, _message), do: :ok
  def ensure!(_false, message), do: raise(message)

  def store!(input, folder) do
    filename = input.filename

    case Upload.store({input, folder}) do
      {:ok, ^filename} -> Process.put(:uploaded, [filename | Process.get(:uploaded, [])])
      other -> raise "store returned #{describe(other)}"
    end
  end

  def signed_get(name, folder) do
    url = Upload.url({name, folder}, :original, signed: true, expires_in: 300)
    Req.get!(url, retry: false, decode_body: false)
  end

  def ensure_gone!(name, folder) do
    %{status: status} = signed_get(name, folder)
    ensure!(status == 404, "expected 404 after deleting, got #{status}")
  end

  def describe({:error, [reason | _]}), do: "an error: #{describe(reason)}"
  def describe({:error, reason}), do: "an error: #{describe(reason)}"

  def describe(%Req.Response{} = response) do
    code = response |> Req.Response.get_header("x-ms-error-code") |> Enum.join()
    body = if is_binary(response.body), do: response.body, else: inspect(response.body)
    "HTTP #{response.status} #{code} #{String.slice(body, 0, 1500)}"
  end

  def describe(%{__exception__: true} = error), do: Exception.message(error)
  def describe(other), do: inspect(other)

  # Azure's authentication errors quote the signature that was sent. The string
  # it signed is kept, because it's what explains a mismatch.
  def scrub(text) do
    text =
      case System.get_env("AZURE_ACCESS_KEY") do
        key when key in [nil, ""] -> text
        key -> String.replace(text, key, "[key]")
      end

    text = Regex.replace(~r/(sig=)[^&\s"'<]+/, text, "\\1[redacted]")
    text = Regex.replace(~r/(Bearer )[^\s"'<]+/, text, "\\1[redacted]")
    Regex.replace(~r/(in the HTTP request ')[^']*/, text, "\\1[redacted]")
  end
end

defmodule Smoke.Run do
  alias Smoke.Upload

  def run do
    access_key = Application.get_env(:waffle_azure, :access_key)
    managed_identity? = access_key == nil

    if managed_identity? do
      IO.puts("Using the managed identity: #{inspect(Waffle.Storage.Azure.Client.credential())}")
    end

    folder = "waffle-azure-smoke-#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
    IO.puts("Testing under #{System.fetch_env!("AZURE_TEST_CONTAINER")}/#{folder}/\n")

    block = :binary.copy("a", 1024 * 1024)

    cases = [
      {"small file", "small.txt", "hello from waffle_azure"},
      {"empty file", "empty.txt", ""},
      {"large file (blocks)", "large.txt", :crypto.strong_rand_bytes(9 * 1024 * 1024 + 123)},
      {"stream (blocks)", "stream.txt", {:stream, [block, block, block, block, block, "end"]}},
      {"space and accents", "photo ç é.txt", "accents"},
      {"symbols", "a+b&c=d #1 50%.txt", "symbols"}
    ]

    for {label, name, contents} <- cases do
      {input, expected} =
        case contents do
          {:stream, chunks} ->
            {%{filename: name, stream: Stream.map(chunks, & &1)}, IO.iodata_to_binary(chunks)}

          binary ->
            {%{filename: name, binary: binary}, binary}
        end

      if Smoke.check("#{label}: upload", fn -> Smoke.store!(input, folder) end) do
        response = Smoke.signed_get(name, folder)

        Smoke.check("#{label}: signed download matches", fn ->
          Smoke.ensure!(response.status == 200, "got #{Smoke.describe(response)}")
          Smoke.ensure!(response.body == expected, "got #{byte_size(response.body)} bytes back")
        end)

        Smoke.check("#{label}: blob properties", fn ->
          type = Req.Response.get_header(response, "content-type")
          cache = Req.Response.get_header(response, "cache-control")
          Smoke.ensure!(type == ["text/plain"], "content-type was #{inspect(type)}")
          Smoke.ensure!(cache == ["max-age=60"], "cache-control was #{inspect(cache)}")
        end)

        Smoke.check("#{label}: delete", fn ->
          Smoke.ensure!(Upload.delete({name, folder}) == :ok, "delete didn't return :ok")
          Smoke.ensure_gone!(name, folder)
        end)
      end
    end

    by_url = "delete-by-url.txt"

    if Smoke.check("delete by full URL: upload", fn ->
         Smoke.store!(%{filename: by_url, binary: "x"}, folder)
       end) do
      url = Upload.url({by_url, folder})

      # Either answer can be right, depending on the container's access level, so
      # this is only reported for you to compare with what you expect.
      %{status: status} = Req.get!(url, retry: false, decode_body: false)
      IO.puts("INFO  unsigned URL returned HTTP #{status} (403 or 404 = private, 200 = public)")

      Smoke.check("delete by full URL: delete", fn ->
        :ok = Waffle.Storage.Azure.delete(Upload, :original, {%{file_name: url}, nil})
        Smoke.ensure_gone!(by_url, folder)
      end)
    end

    if managed_identity? do
      Smoke.check("signed URLs are user delegation SAS URLs", fn ->
        url = Upload.url({"small.txt", folder}, :original, signed: true)
        Smoke.ensure!(url =~ "skoid=", "the signed URL had no user delegation key fields")
      end)
    end

    wrong_key = "wrong-key.txt"

    if managed_identity? do
      IO.puts("SKIP  wrong key: there's no key with a managed identity")
    else
      wrong_key_check(wrong_key, folder, access_key)
    end

    leftovers(folder)
  end

  defp wrong_key_check(wrong_key, folder, access_key) do
    Smoke.check("wrong key: upload is rejected with an error", fn ->
      Application.put_env(:waffle_azure, :access_key, Base.encode64("definitely the wrong key"))

      result =
        try do
          Upload.store({%{filename: wrong_key, binary: "x"}, folder})
        after
          Application.put_env(:waffle_azure, :access_key, access_key)
        end

      case result do
        {:error, [%Req.Response{status: 403}]} ->
          :ok

        other ->
          Process.put(:uploaded, [wrong_key | Process.get(:uploaded, [])])
          raise "expected a 403 error, got #{Smoke.describe(other)}"
      end
    end)
  end

  defp leftovers(folder) do
    leftovers =
      for name <- Process.get(:uploaded, []),
          Upload.delete({name, folder}) == :ok,
          Smoke.signed_get(name, folder).status != 404 do
        "#{folder}/#{name}"
      end

    IO.puts("")

    if leftovers != [] do
      Process.put(:failures, Process.get(:failures, 0) + 1)
      IO.puts("FAIL  couldn't confirm these were deleted, so check them by hand:")
      Enum.each(leftovers, &IO.puts("      #{&1}"))
    end

    case Process.get(:failures, 0) do
      0 ->
        IO.puts("All checks passed.")

      failures ->
        IO.puts("#{failures} check(s) failed.")
        System.halt(1)
    end
  end
end

Smoke.Run.run()
