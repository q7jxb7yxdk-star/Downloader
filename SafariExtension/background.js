browser.runtime.onInstalled.addListener(() => {
  browser.contextMenus.create({
    id: "download-with-downloader",
    title: "Download with Downloader",
    contexts: ["link"]
  });
});

browser.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId !== "download-with-downloader" || !info.linkUrl) {
    return;
  }

  const url = `downloader://add?url=${encodeURIComponent(info.linkUrl)}`;
  browser.tabs.create({ url });
});
