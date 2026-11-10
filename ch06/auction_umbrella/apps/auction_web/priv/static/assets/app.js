// This file is for your main application javascript.
//
// We no longer use a bundler like webpack: assets are served
// straight from priv/static/assets. The `phoenix.js` asset is
// loaded before this file in the layout, so `window.Phoenix`
// is available when channels are wired up.
//
// Channels are not wired up yet in this chapter. Once they are,
// uncomment and adapt the code below (it used to live in
// assets/js/socket.js and was imported from assets/js/app.js):
//
//   let socket = new Phoenix.Socket("/socket", {params: {token: window.userToken}})
//   socket.connect()
//
//   let channel = socket.channel("topic:subtopic", {})
//   channel.join()
//     .receive("ok", resp => { console.log("Joined successfully", resp) })
//     .receive("error", resp => { console.log("Unable to join", resp) })
//
// The token can be passed to JavaScript inside a script tag in
// lib/auction_web/components/layouts/app.html.heex:
//
//   <script>window.userToken = "...";</script>
//
// and verified in the `connect/3` function in
// lib/auction_web/channels/user_socket.ex:
//
//   def connect(%{"token" => token}, socket, _connect_info) do
//     # max_age: 1209600 is equivalent to two weeks in seconds
//     case Phoenix.Token.verify(socket, "user socket", token, max_age: 1209600) do
//       {:ok, user_id} ->
//         {:ok, assign(socket, :user, user_id)}
//       {:error, _reason} ->
//         :error
//     end
//   end
