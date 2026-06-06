const downloadableExtensions = new Set([
  "7z", "aac", "avi", "bin", "bz2", "csv", "dmg", "doc", "docx", "epub",
  "exe", "flac", "gif", "gz", "iso", "jpeg", "jpg", "m4a", "m4v", "mkv",
  "mov", "mp3", "mp4", "msi", "pdf", "pkg", "png", "ppt", "pptx", "rar",
  "tar", "torrent", "tsv", "txt", "wav", "webm", "webp", "xls", "xlsx",
  "xz", "zip"
]);

let automaticallyCaptureDownloads = true;
const pendingProbes = new Map();

safari.self.addEventListener("message", (event) => {
  if (event.name === "auto-capture-setting") {
    automaticallyCaptureDownloads = event.message && event.message.enabled === true;
    return;
  }

  if (event.name === "download-probe-result") {
    const requestID = event.message && event.message.requestID;
    const pending = requestID ? pendingProbes.get(requestID) : null;
    if (!pending) {
      return;
    }

    pendingProbes.delete(requestID);
    clearTimeout(pending.timeoutID);
    if (event.message.isTorrent !== true) {
      window.location.assign(pending.url);
    }
  }
}, false);

dispatchToExtension("request-auto-capture-setting");

window.addEventListener("focus", () => {
  dispatchToExtension("request-auto-capture-setting");
});

document.addEventListener("contextmenu", (event) => {
  const link = closestLink(event);
  safari.extension.setContextMenuEventUserInfo(event, {
    url: link ? link.href : ""
  });
}, false);

document.addEventListener("click", (event) => {
  if (!automaticallyCaptureDownloads || event.defaultPrevented || event.button !== 0) {
    return;
  }

  const request = downloadRequest(event);
  if (!request) {
    return;
  }

  event.preventDefault();
  event.stopPropagation();

  if (request.kind === "probe") {
    const requestID = createRequestID();
    const timeoutID = setTimeout(() => {
      const pending = pendingProbes.get(requestID);
      if (!pending) {
        return;
      }
      pendingProbes.delete(requestID);
      window.location.assign(pending.url);
    }, 12000);
    pendingProbes.set(requestID, {
      url: request.url,
      timeoutID
    });
    dispatchToExtension("probe-download", {
      requestID,
      url: request.url
    });
    return;
  }

  dispatchToExtension("auto-capture-download", {
    url: request.url,
    kind: request.kind
  });
}, true);

function dispatchToExtension(name, message) {
  try {
    safari.extension.dispatchMessage(name, message);
  } catch (error) {
    console.error("Downloader Safari Extension:", error);
  }
}

function closestLink(event) {
  for (const node of event.composedPath()) {
    if (node instanceof HTMLAnchorElement && node.href) {
      return node;
    }
    if (node instanceof Element) {
      const link = node.closest("a[href]");
      if (link) {
        return link;
      }
    }
  }
  return null;
}

function downloadRequest(event) {
  const link = closestLink(event);
  if (link) {
    const url = normalizedURL(link.href);
    if (!url) {
      return null;
    }

    const torrent = isTorrentElement(link, url);
    if (torrent || link.hasAttribute("download") || isKnownDownloadURL(url)) {
      return {
        url: url.href,
        kind: torrent ? "torrent" : null
      };
    }

    if (isProbableDownloadEndpoint(url)) {
      return {
        url: url.href,
        kind: "probe"
      };
    }
  }

  const actionable = closestActionableElement(event);
  if (!actionable || !isTorrentElement(actionable)) {
    return null;
  }

  const url = actionableURL(actionable);
  if (!url) {
    return null;
  }

  return {
    url: url.href,
    kind: "torrent"
  };
}

function closestActionableElement(event) {
  for (const node of event.composedPath()) {
    if (!(node instanceof Element)) {
      continue;
    }

    if (node.matches("button, input[type='button'], input[type='submit'], [role='button']")) {
      return node;
    }

    const actionable = node.closest(
      "button, input[type='button'], input[type='submit'], [role='button']"
    );
    if (actionable) {
      return actionable;
    }
  }
  return null;
}

function actionableURL(element) {
  const candidates = [
    element.getAttribute("formaction"),
    element.getAttribute("data-download-url"),
    element.getAttribute("data-url"),
    element.getAttribute("data-href"),
    element.closest("form[action]")?.action
  ];

  for (const candidate of candidates) {
    const url = normalizedURL(candidate);
    if (url) {
      return url;
    }
  }
  return null;
}

function isTorrentElement(element, url = null) {
  if (url && torrentURLPattern(url)) {
    return true;
  }

  const indicators = [
    element.getAttribute("download"),
    element.getAttribute("type"),
    element.getAttribute("data-type"),
    element.getAttribute("data-filetype"),
    element.getAttribute("data-filename"),
    element.getAttribute("title"),
    element.getAttribute("aria-label"),
    element instanceof HTMLInputElement ? element.value : null,
    element.textContent
  ].filter(Boolean).join(" ");

  return /application\/x-bittorrent/i.test(indicators)
    || /(^|[\s._-])torrent($|[\s._-])/i.test(indicators);
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
  return downloadableExtensions.has(extension);
}

function torrentURLPattern(url) {
  return url.protocol === "magnet:"
    || /\.torrent(?:$|[?#])/i.test(url.href);
}

function isProbableDownloadEndpoint(url) {
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return false;
  }

  return /(^|\/)(file|download)(\/|$)/i.test(url.pathname);
}

function createRequestID() {
  if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function normalizedURL(value) {
  if (!value) {
    return null;
  }

  try {
    const url = new URL(value, document.baseURI);
    return ["http:", "https:", "magnet:"].includes(url.protocol) ? url : null;
  } catch {
    return null;
  }
}
