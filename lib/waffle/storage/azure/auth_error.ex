defmodule Waffle.Storage.Azure.AuthError do
  @moduledoc """
  Raised or returned when the adapter can't get the credentials it needs from
  Microsoft Entra ID, such as a managed identity token or a user delegation key.

  It appears as the `reason` in `{:error, reason}` results, and is raised by
  `Waffle.Storage.Azure.url/4` when a signed URL can't be built. The message
  never contains a token or key.
  """

  defexception [:message]
end
