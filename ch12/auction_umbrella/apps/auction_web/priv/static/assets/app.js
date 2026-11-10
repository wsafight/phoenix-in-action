// The vendored phoenix.js (copied from deps/phoenix/priv/static)
// is loaded before this file and exposes window.Phoenix.
// phoenix_html.js is also loaded for link method support (e.g. "Log out").

let socket = new window.Phoenix.Socket("/socket", {
  params: { token: window.userToken },
});

socket.connect();

let match = document.location.pathname.match(/\/items\/(\d+)$/);
if (match) {
  let itemId = match[1];
  let channel = socket.channel(`item:${itemId}`, {});

  channel.on("new_bid", (data) => {
    console.log("new_bid message received", data);
    const elem = document.getElementById("bids");
    elem.insertAdjacentHTML("afterbegin", data.body);
  });

  channel
    .join()
    .receive("ok", (resp) => {
      console.log("Joined successfully", resp);
    })
    .receive("error", (resp) => {
      console.log("Unable to join", resp);
    });
}
