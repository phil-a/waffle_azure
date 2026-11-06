defmodule Waffle.Storage.Azure.Client do
  @moduledoc false
  # The small part of the Blob Storage REST API that the adapter needs, along
  # with request authorization and SAS signing:
  #
  #   * https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key
  #   * https://learn.microsoft.com/rest/api/storageservices/authorize-with-azure-active-directory
  #   * https://learn.microsoft.com/rest/api/storageservices/create-service-sas
  #   * https://learn.microsoft.com/rest/api/storageservices/create-user-delegation-sas

  alias Waffle.Storage.Azure.{AuthError, ManagedIdentity, TokenCache}

  @api_version "2021-12-02"

  # A user delegation key is valid for at most 7 days, and a SAS signed with it
  # can't outlast it. The hour is room for the clock skew allowance and the
  # cache's refresh margin.
  @max_key_lifetime 7 * 24 * 60 * 60
  @max_delegated_expires_in @max_key_lifetime - 60 * 60
  @clock_skew 5 * 60

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

    with {:ok, authorization} <- authorization(credential(), method, url, query, headers, body) do
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
  end

  def blob_url(container, blob) do
    endpoint() <> "/" <> encode_path(path(container, blob))
  end

  def signed_blob_url(container, blob, expires_in) do
    case credential() do
      :shared_key ->
        service_sas_url(container, blob, expires_in)

      {:managed_identity, _options} = credential ->
        user_delegation_sas_url(credential, container, blob, expires_in)
    end
  end

  def encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn char -> URI.char_unreserved?(char) end))
  end

  # Reads the :credential setting, which decides how requests are authorized.
  def credential do
    case Application.get_env(:waffle_azure, :credential, :shared_key) do
      :shared_key ->
        :shared_key

      :managed_identity ->
        {:managed_identity, []}

      {:managed_identity, options} = credential when is_list(options) ->
        case Keyword.keys(options) -- [:client_id] do
          [] -> credential
          unknown -> raise ArgumentError, "unknown :managed_identity options #{inspect(unknown)}"
        end

      other ->
        raise ArgumentError,
              "invalid :credential #{inspect(other)} for :waffle_azure, expected :shared_key, " <>
                ~s(:managed_identity, or {:managed_identity, client_id: "..."})
    end
  end

  #
  # Shared access signatures
  #

  defp service_sas_url(container, blob, expires_in) do
    expiry = iso8601(System.os_time(:second) + expires_in)

    # Unused optional fields still need their line in the string to sign.
    string_to_sign =
      Enum.join(
        [
          "r",
          "",
          expiry,
          canonical_sas_resource(container, blob),
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
        sig: sign(Base.decode64!(access_key()), string_to_sign)
      )

    blob_url(container, blob) <> "?" <> query
  end

  defp user_delegation_sas_url(credential, container, blob, expires_in) do
    if expires_in > @max_delegated_expires_in do
      raise ArgumentError,
            "signed URLs made with a managed identity can be valid for at most " <>
              "#{@max_delegated_expires_in} seconds, but :expires_in was #{expires_in}"
    end

    expires_at = System.os_time(:second) + expires_in
    expiry = iso8601(expires_at)
    key = user_delegation_key!(credential, expires_at)

    # The layout for version 2020-12-06 and later. Unused optional fields still
    # need their line in the string to sign.
    string_to_sign =
      Enum.join(
        [
          "r",
          "",
          expiry,
          canonical_sas_resource(container, blob),
          key.object_id,
          key.tenant_id,
          key.start,
          key.expiry,
          key.service,
          key.version,
          "",
          "",
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
        skoid: key.object_id,
        sktid: key.tenant_id,
        skt: key.start,
        ske: key.expiry,
        sks: key.service,
        skv: key.version,
        sig: sign(Base.decode64!(key.value), string_to_sign)
      )

    blob_url(container, blob) <> "?" <> query
  end

  defp canonical_sas_resource(container, blob), do: "/blob/#{account()}/#{path(container, blob)}"

  # One key signs any number of URLs, so it is cached for as long as it lasts.
  defp user_delegation_key!(credential, valid_until) do
    cache_key = {:user_delegation_key, endpoint(), credential}
    fetch_key = fn -> get_user_delegation_key(valid_until) end

    case TokenCache.fetch(cache_key, valid_until, fetch_key) do
      {:ok, key} ->
        key

      {:error, %Req.Response{} = response} ->
        raise AuthError,
              "couldn't get a user delegation key to sign the URL: " <>
                String.trim("HTTP #{response.status} #{error_code(response)}")

      {:error, exception} ->
        raise AuthError,
              "couldn't get a user delegation key to sign the URL: " <>
                Exception.message(exception)
    end
  end

  defp get_user_delegation_key(valid_until) do
    now = System.os_time(:second)

    # Long-lived, so that it can sign many URLs, but always long enough to
    # outlast the URL being signed by more than the cache's refresh margin.
    expiry =
      (now + 24 * 60 * 60)
      |> max(valid_until + 2 * @clock_skew)
      |> min(now + @max_key_lifetime - 2 * @clock_skew)

    body =
      ~s(<?xml version="1.0" encoding="utf-8"?><KeyInfo>) <>
        "<Start>#{iso8601(now - @clock_skew)}</Start>" <>
        "<Expiry>#{iso8601(expiry)}</Expiry></KeyInfo>"

    case request(:post, "", [restype: "service", comp: "userdelegationkey"], [], body) do
      {:ok, %Req.Response{status: 200, body: xml}} -> parse_user_delegation_key(xml)
      {:ok, response} -> {:error, response}
      {:error, _exception} = error -> error
    end
  end

  @key_fields [
    object_id: "SignedOid",
    tenant_id: "SignedTid",
    start: "SignedStart",
    expiry: "SignedExpiry",
    service: "SignedService",
    version: "SignedVersion",
    value: "Value"
  ]

  # The response is a flat list of elements, none of which needs unescaping.
  defp parse_user_delegation_key(xml) do
    fields =
      Map.new(@key_fields, fn {field, element} ->
        {field, Regex.run(~r{<#{element}>([^<]+)</#{element}>}, xml, capture: :all_but_first)}
      end)

    with true <- Enum.all?(fields, fn {_field, match} -> match end),
         key = Map.new(fields, fn {field, [value]} -> {field, value} end),
         {:ok, expiry, _offset} <- DateTime.from_iso8601(key.expiry) do
      {:ok, key, DateTime.to_unix(expiry)}
    else
      _invalid -> {:error, %AuthError{message: "unexpected user delegation key response"}}
    end
  end

  #
  # Request authorization
  #

  defp authorization(:shared_key, method, url, query, headers, body) do
    {:ok, shared_key_authorization(method, url, query, headers, body)}
  end

  defp authorization(
         {:managed_identity, options} = credential,
         _method,
         _url,
         _query,
         _headers,
         _body
       ) do
    fetch_token = fn -> ManagedIdentity.fetch_token(options) end
    now = System.os_time(:second)

    with {:ok, token} <- TokenCache.fetch({:token, credential}, now, fetch_token) do
      {:ok, "Bearer " <> token}
    end
  end

  defp shared_key_authorization(method, url, query, headers, body) do
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

    "SharedKey #{account()}:#{sign(Base.decode64!(access_key()), string_to_sign)}"
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

  defp sign(key, string_to_sign) do
    :hmac
    |> :crypto.mac(:sha256, key, string_to_sign)
    |> Base.encode64()
  end

  #
  # Helpers
  #

  defp path(container, blob), do: container <> "/" <> blob

  defp expect_created({:ok, %Req.Response{status: 201}}), do: :ok
  defp expect_created({:ok, response}), do: {:error, response}
  defp expect_created({:error, _exception} = error), do: error

  defp error_code(response) do
    response |> Req.Response.get_header("x-ms-error-code") |> Enum.join()
  end

  defp query_string([]), do: ""
  defp query_string(query), do: "?" <> URI.encode_query(query)

  defp http_date(datetime), do: Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")

  defp iso8601(unix_seconds) do
    unix_seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

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
