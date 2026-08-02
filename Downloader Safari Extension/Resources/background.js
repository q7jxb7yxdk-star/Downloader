const nativeApplicationIdentifier = "com.sunny.Downloader.Downloader-Safari-Extension";
const menuId = "download-with-downloader";
const recentCaptures = new Map();
const duplicateWindow = 3000;

const downloadableExtensions = new Set([
  "7z", "aac", "avi", "bin", "bz2", "csv", "dmg", "doc", "docx", "epub",
  "exe", "flac", "gif", "gz", "iso", "jpeg", "jpg", "m4a", "m4v", "mkv",
  "mov", "mp3", "mp4", "msi", "pdf", "pkg", "png", "ppt", "pptx", "rar",
  "tar", "torrent", "tsv", "txt", "wav", "webm", "webp", "xls", "xlsx",
  "xz", "zip"
]);

resetContextMenu();

browser.runtime.onInstalled.addListener(() => {
  resetContextMenu();
});
browser.runtime.onStartup.addListener(resetContextMenu);

browser.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId === menuId && info.linkUrl) {
    queueDownload(info.linkUrl, null, null);
  }
});

browser.runtime.onMessage.addListener((message) => {
  if (!message || typeof message.name !== "string") {
    return Promise.resolve({});
  }

  if (message.name === "request-auto-capture-setting") {
    return sendNativeMessage({
      name: "request-auto-capture-setting"
    });
  }

  if (message.name === "auto-capture-download") {
    return queueDownload(message.url, message.kind || null, message.displayName || null);
  }

  if (message.name === "probe-download") {
    return sendNativeMessage({
      name: "probe-download",
      requestID: message.requestID,
      url: message.url
    });
  }

  return Promise.resolve({});
});

if (browser.webNavigation && browser.webNavigation.onBeforeNavigate) {
  browser.webNavigation.onBeforeNavigate.addListener((details) => {
    if (details.frameId !== 0 || !details.url) {
      return;
    }

    let url;
    try {
      url = new URL(details.url);
    } catch {
      return;
    }

    const knownDownload = isKnownDownloadURL(url);
    const probableDownload = isProbableDownloadEndpoint(url);
    if ((!knownDownload && !probableDownload) || !shouldCapture(details.url)) {
      return;
    }

    const action = knownDownload
      ? queueDownload(details.url, torrentURLPattern(url) ? "torrent" : null, downloadableFileNameFromQuery(url))
      : probeDownload(details.url, `navigation-${details.tabId}-${Date.now()}`);

    action
      .then((response) => {
        if (response && response.queued === true && details.tabId >= 0) {
          browser.tabs.remove(details.tabId).catch(() => {});
        }
      });
  }, {
    url: [
      { schemes: ["http"] },
      { schemes: ["https"] }
    ]
  });
}

function resetContextMenu() {
  browser.contextMenus.removeAll().finally(() => {
    browser.contextMenus.create({
      id: menuId,
      title: "Download with Downloader",
      contexts: ["link"]
    });
  });
}

function queueDownload(url, kind, name) {
  if (!url) {
    return Promise.resolve({ queued: false });
  }

  return sendNativeMessage({
    name: "auto-capture-download",
    url,
    kind,
    displayName: name
  });
}

function probeDownload(url, requestID) {
  if (!url) {
    return Promise.resolve({ queued: false });
  }

  return sendNativeMessage({
    name: "probe-download",
    requestID,
    url
  });
}

function sendNativeMessage(message) {
  return browser.runtime.sendNativeMessage(nativeApplicationIdentifier, message)
    .catch((error) => {
      console.error("Downloader Safari Extension native message failed:", error);
      return { error: String(error) };
    });
}

function shouldCapture(url) {
  const now = Date.now();
  for (const [capturedURL, capturedAt] of recentCaptures.entries()) {
    if (now - capturedAt >= duplicateWindow) {
      recentCaptures.delete(capturedURL);
    }
  }

  const capturedAt = recentCaptures.get(url);
  if (capturedAt && now - capturedAt < duplicateWindow) {
    return false;
  }

  recentCaptures.set(url, now);
  return true;
}

function isKnownDownloadURL(url) {
  if (url.protocol === "magnet:") {
    return true;
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return false;
  }

  const fileName = url.pathname.split("/").pop() || "";
  const extension = fileName.includes(".") ? fileName.split(".").pop().toLowerCase() : "";
  return downloadableExtensions.has(extension) || downloadableFileNameFromQuery(url) !== null;
}

function isProbableDownloadEndpoint(url) {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return false;
  }

  return /(^|\/)(file|download)(\/|$)/i.test(url.pathname);
}

function torrentURLPattern(url) {
  return url.protocol === "magnet:"
    || /\.torrent(?:$|[?#])/i.test(url.href);
}

function downloadableFileNameFromQuery(url) {
  const candidates = [];
  for (const [key, value] of url.searchParams.entries()) {
    const lowerKey = key.toLowerCase();
    if (
      lowerKey.includes("filename")
      || lowerKey === "response-content-disposition"
      || lowerKey === "rscd"
      || lowerKey === "content-disposition"
    ) {
      candidates.push(value);
    }
  }

  for (const candidate of candidates) {
    const fileName = fileNameFromDisposition(candidate) || fileNameFromValue(candidate);
    if (fileName && hasDownloadableExtension(fileName)) {
      return fileName;
    }
  }
  return null;
}

function fileNameFromDisposition(value) {
  const utf8Match = value.match(/filename\*\s*=\s*UTF-8''([^;]+)/i);
  if (utf8Match) {
    return safeDecodeURIComponent(utf8Match[1].trim().replace(/^["']|["']$/g, ""));
  }

  const match = value.match(/filename\s*=\s*(?:"([^"]+)"|([^;]+))/i);
  if (!match) {
    return null;
  }
  return (match[1] || match[2] || "").trim().replace(/^["']|["']$/g, "");
}

function fileNameFromValue(value) {
  const trimmed = value.trim().replace(/^["']|["']$/g, "");
  if (!trimmed) {
    return null;
  }
  return trimmed.split(/[\\/]/).pop();
}

function hasDownloadableExtension(fileName) {
  const cleanName = fileName.split(/[?#]/)[0];
  const extension = cleanName.includes(".") ? cleanName.split(".").pop().toLowerCase() : "";
  return downloadableExtensions.has(extension);
}

function safeDecodeURIComponent(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}
