// For phoenix_html support, including form and button helpers
// copy the following scripts into your javascript bundle:
// * deps/phoenix_html/priv/static/phoenix_html.js

// To use Phoenix channels, the first step is to import Socket,
// and connect at the socket path in "lib/auction_web/endpoint.ex".
// The phoenix.js file is loaded in the layout before this file.
//
// let socket = new window.Phoenix.Socket("/socket", {params: {token: window.userToken}})

// When you connect, you'll often need to authenticate the client.
// For example, imagine you have an authentication plug, `MyAuth`,
// which authenticates the session and assigns a `:current_user`.
// If the current user exists you can assign the user's token in
// the connection for use in the layout.
//
// Finally, connect to the socket:
//
// socket.connect()
// let channel = socket.channel("topic:subtopic", {})
// channel.join()
//   .receive("ok", resp => { console.log("Joined successfully", resp) })
//   .receive("error", resp => { console.log("Unable to join", resp) })
