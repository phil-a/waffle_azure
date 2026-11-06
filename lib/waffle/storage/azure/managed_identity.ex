defmodule Waffle.Storage.Azure.ManagedIdentity do
  @moduledoc false
  # Gets Microsoft Entra access tokens for Azure Storage from the managed
  # identity endpoint of the Azure service the app runs on:
  #
  #   * App Service, Functions and Container Apps set IDENTITY_ENDPOINT and
  #     IDENTITY_HEADER: https://learn.microsoft.com/azure/app-service/overview-managed-identity
  #   * Everywhere else, such as VMs and AKS nodes, the Instance Metadata Service
  #     answers: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token

  alias Waffle.Storage.Azure.AuthError

  @resource "https://storage.azure.com/"
  @imds_url "http://169.254.169.254/metadata/identity/oauth2/token"

  @doc """
  Returns `{:ok, token, expires_at}`, with `expires_at` in Unix seconds, or
  `{:error, exception}`.

  Pass `:client_id` to use a user-assigned identity. Without it, the endpoint
  uses the system-assigned identity.
  """
  def fetch_token(options) do
    {url, params, headers} = endpoint(options)

    [
      method: :get,
      url: url,
      params: params,
      headers: headers,
      # The endpoints ask clients to retry throttling and server errors.
      retry: :transient,
      # Both endpoints are local to the host, so they connect at once if they
      # exist. Away from Azure, this reports the problem well within Waffle's
      # default 15 second upload timeout.
      connect_options: [timeout: 1_000]
    ]
    |> Req.new()
    |> Req.merge(Application.get_env(:waffle_azure, :request_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}} ->
        with {:ok, expires_at} <- expires_at(body), do: {:ok, token, expires_at}

      {:ok, response} ->
        {:error,
         %AuthError{message: "couldn't get a managed identity token: " <> describe(response)}}

      {:error, exception} ->
        {:error,
         %AuthError{
           message:
             "couldn't reach the managed identity endpoint at #{url}: " <>
               Exception.message(exception)
         }}
    end
  end

  defp endpoint(options) do
    identity = Enum.filter([client_id: options[:client_id]], fn {_key, value} -> value end)

    case {System.get_env("IDENTITY_ENDPOINT"), System.get_env("IDENTITY_HEADER")} do
      {endpoint, header} when endpoint not in [nil, ""] and header not in [nil, ""] ->
        params = [resource: @resource, "api-version": "2019-08-01"] ++ identity
        {endpoint, params, [{"x-identity-header", header}]}

      _not_app_service ->
        params = [resource: @resource, "api-version": "2018-02-01"] ++ identity
        {@imds_url, params, [{"metadata", "true"}]}
    end
  end

  # Both endpoints give expires_on as a string of Unix seconds.
  defp expires_at(%{"expires_on" => expires_on}), do: to_seconds(expires_on)

  defp expires_at(%{"expires_in" => expires_in}) do
    with {:ok, seconds} <- to_seconds(expires_in), do: {:ok, System.os_time(:second) + seconds}
  end

  defp expires_at(_body) do
    {:error, %AuthError{message: "the managed identity token response had no expiry time"}}
  end

  defp to_seconds(value) when is_integer(value), do: {:ok, value}

  defp to_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> {:ok, seconds}
      _other -> {:error, %AuthError{message: "unexpected token expiry time #{inspect(value)}"}}
    end
  end

  defp to_seconds(value) do
    {:error, %AuthError{message: "unexpected token expiry time #{inspect(value)}"}}
  end

  # Entra errors have error and error_description; App Service's own errors
  # have a message. Neither contains a token.
  defp describe(%Req.Response{status: status, body: body}) do
    detail =
      case body do
        %{"error_description" => description} -> "#{body["error"]}: #{description}"
        %{"error" => error} when is_binary(error) -> error
        %{"message" => message} -> message
        body when is_binary(body) -> String.slice(body, 0, 500)
        body -> inspect(body, limit: 20)
      end

    String.trim("HTTP #{status} #{detail}")
  end
end
