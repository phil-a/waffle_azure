defmodule Waffle.Storage.Azure.Client do
  @moduledoc false
  # The small part of the Blob Storage REST API that the adapter needs, along
  # with Shared Key and service SAS signing:
  #
  #   * https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key
  #   * https://learn.microsoft.com/rest/api/storageservices/create-service-sas

  @api_version "2021-12-02"

  def put_blob(container, blob, body, headers) do
    :put
    |> request(path(container, blob), [], [{"x-ms-blob-type", "BlockBlob"} | headers], body)
    |> expect_created()
  end

  def put_block(container, blob, block_id, chunk) do
    query = [comp: "block", blockid: block_id]

    :put
    |> request(path(container, blob), query, [], chunk)
    |> expect_created()
  end

  def put_block_list(container, blob, block_ids, headers) do
    blocks = Enum.map(block_ids, &["<Latest>", &1, "</Latest>"])

    body =
      IO.iodata_to_binary([
        ~s(<?xml version="1.0" encoding="utf-8"?><BlockList>),
        blocks,
        "</BlockList>"
      ])

    :put
    |> request(path(container, blob), [comp: "blocklist"], headers, body)
    |> expect_created()
  end

  # An already missing blob counts as deleted.
  def delete_blob(container, blob) do
    case request(:delete, path(container, blob)) do
      {:ok, %Req.Response{status: status}} when status in [202, 404] -> :ok
      {:ok, response} -> {:error, response}
      {:error, _exception} = error -> error
    end
  end

  def request(method, path, query \\ [], headers \\ [], body \\ nil) do
    url = endpoint() <> "/" <> encode_path(path) <> query_string(query)

    headers = [
      {"x-ms-date", http_date(DateTime.utc_now())},
      {"x-ms-version", @api_version}
      | headers
    ]

    authorization = authorization(method, url, query, headers, body)

    [
      method: method,
      url: url,
      headers: [{"authorization", authorization} | headers],
      body: body,
      # Every request made here is idempotent, so it is safe to retry the
      # transient failures Azure asks clients to retry, such as 503 ServerBusy.
      retry: :transient
    ]
    |> Req.new()
    |> Req.merge(Application.get_env(:waffle_azure, :request_options, []))
    |> Req.request()
  end

  def blob_url(container, blob) do
    endpoint() <> "/" <> encode_path(path(container, blob))
  end

  def signed_blob_url(container, blob, expires_in) do
    expiry =
      DateTime.utc_now()
      |> DateTime.add(expires_in, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    # Unused optional fields still need their line in the string to sign.
    string_to_sign =
      Enum.join(
        [
          "r",
          "",
          expiry,
          "/blob/#{account()}/#{path(container, blob)}",
          "",
          "",
          "",
          @api_version,
          "b",
          "",
          "",
          "",
          "",
          "",
          "",
          ""
        ],
        "\n"
      )

    query =
      URI.encode_query(
        sv: @api_version,
        sr: "b",
        sp: "r",
        se: expiry,
        sig: sign(string_to_sign)
      )

    blob_url(container, blob) <> "?" <> query
  end

  def encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  defp path(container, blob), do: container <> "/" <> blob

  defp expect_created({:ok, %Req.Response{status: 201}}), do: :ok
  defp expect_created({:ok, response}), do: {:error, response}
  defp expect_created({:error, _exception} = error), do: error

  defp query_string([]), do: ""
  defp query_string(query), do: "?" <> URI.encode_query(query)

  defp authorization(method, url, query, headers, body) do
    content_length =
      case IO.iodata_length(body || "") do
        0 -> ""
        length -> Integer.to_string(length)
      end

    # The adapter only sets blob properties through x-ms-* headers, so of the
    # standard headers only Content-Length is ever non-empty.
    standard_headers = ["", "", content_length, "", "", "", "", "", "", "", ""]

    string_to_sign =
      Enum.join([method |> Atom.to_string() |> String.upcase() | standard_headers], "\n") <>
        "\n" <> canonicalized_headers(headers) <> canonicalized_resource(url, query)

    "SharedKey #{account()}:#{sign(string_to_sign)}"
  end

  defp canonicalized_headers(headers) do
    headers
    |> Enum.sort()
    |> Enum.map_join(fn {name, value} -> "#{name}:#{String.trim(value)}\n" end)
  end

  defp canonicalized_resource(url, query) do
    parameters =
      query
      |> Enum.map(fn {name, value} -> {Atom.to_string(name), value} end)
      |> Enum.sort()
      |> Enum.map_join(fn {name, value} -> "\n#{name}:#{value}" end)

    "/" <> account() <> URI.parse(url).path <> parameters
  end

  defp sign(string_to_sign) do
    :hmac
    |> :crypto.mac(:sha256, Base.decode64!(access_key()), string_to_sign)
    |> Base.encode64()
  end

  defp http_date(datetime), do: Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")

  defp endpoint do
    case Application.get_env(:waffle_azure, :endpoint) do
      nil -> "https://#{account()}.blob.core.windows.net"
      endpoint -> String.trim_trailing(endpoint, "/")
    end
  end

  defp account, do: fetch_config(:account, "AZURE_ACCOUNT")
  defp access_key, do: fetch_config(:access_key, "AZURE_ACCESS_KEY")

  defp fetch_config(key, env_var) do
    Application.get_env(:waffle_azure, key) || System.get_env(env_var) ||
      raise ArgumentError,
            "missing Azure credentials: set `config :waffle_azure, #{key}: ...` " <>
              "or the #{env_var} environment variable"
  end
end
