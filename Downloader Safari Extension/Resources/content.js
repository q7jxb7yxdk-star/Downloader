document.addEventListener("contextmenu", (event) => {
  const link = event.target.closest("a[href]");
  safari.extension.setContextMenuEventUserInfo(event, {
    url: link ? link.href : ""
  });
}, false);
