const menuId = "download-with-downloader";

resetContextMenu();

browser.runtime.onInstalled.addListener(() => {
  resetContextMenu();
});
browser.runtime.onStartup.addListener(resetContextMenu);

browser.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === menuId && info.linkUrl) {
    openDownloaderURL(`downloader://add?url=${encodeURIComponent(info.linkUrl)}`);
  }
});

function resetContextMenu() {
  browser.contextMenus.removeAll().finally(() => {
    browser.contextMenus.create({
      id: menuId,
      title: "Download with Downloader",
      contexts: ["link"]
    });
  });
}

function openDownloaderURL(url) {
  browser.tabs.create({ url, active: true });
}
