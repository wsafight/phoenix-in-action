// For Phoenix.HTML support, including form and button helpers
// copy the following scripts into your javascript bundle:
// * deps/phoenix_html/priv/static/phoenix_html.js

// For Phoenix.Channels support, copy the following scripts
// into your javascript bundle:
// * deps/phoenix/priv/static/phoenix.js

// For Phoenix.LiveView support, copy the following scripts
// into your javascript bundle:
// * deps/phoenix_live_view/priv/static/phoenix_live_view.js

// Connect to an item channel to receive "new_bid" events
// when browsing an item's page.
let socket = new Phoenix.Socket("/socket", { params: { token: window.userToken } })
socket.connect()

let match = document.location.pathname.match(/\/items\/(\d+)$/)
if (match) {
  let itemId = match[1]
  let channel = socket.channel(`item:${itemId}`, {})

  channel.on("new_bid", data => {
    console.log("new_bid message received", data)
    const elem = document.getElementById("bids")
    elem.insertAdjacentHTML("afterbegin", data.body)
  })

  channel
    .join()
    .receive("ok", resp => {
      console.log("Joined successfully", resp)
    })
    .receive("error", resp => {
      console.log("Unable to join", resp)
    })
}
